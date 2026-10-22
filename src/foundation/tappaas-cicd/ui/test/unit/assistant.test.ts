// assistant.test.ts — the assistant (ADR-034 D7, Testing T5) against a fake
// LiteLLM: an HTTP server answering /v1/models and streaming the recorded
// tool-calling exchanges of test/fixtures/litellm-exchange.json. The loop,
// the tool allow-list, the no-apply rule (asked to run a change, it proposes a
// card and applies nothing; a card's job carries the turn), the context in
// the system prompt, the conversation store and its caps, the routes; an
// invented tool's refusal and the recovery; open_console and its navigate event.

import { mkdtempSync, readFileSync, statSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { IncomingMessage, ServerResponse, createServer } from "http";
import { AccessConfig, Me, SetupState } from "../../src/access";
import { Assistant, AssistantEvent, historyFor, shortManifest, writtenCalls } from "../../src/assistant";
import { TOOLS, consoleFormFor, guessArgv, logql, lokiConfig, runTool, timeOf, toolDefs, ToolContext } from "../../src/assistant-tools";
import { Conversations, userKey } from "../../src/conversations";
import { Jobs } from "../../src/jobs";
import { ChatMessage, LiteLLM, StreamParser, chooseModel, parseKeyFile } from "../../src/litellm";
import { Manifests } from "../../src/manifest";
import { Reads } from "../../src/reads";
import { Runner, Streamer } from "../../src/run";
import { ConsoleServer } from "../../src/server";
import { openedText, proposalText, sseEvents } from "../../src/ask";
import { HelpSpec, renderManifest } from "../../../lib/ts/src/help";
import { check, done } from "./check";
import { FIX, fakeSite } from "./fake-site";

const SPEC: HelpSpec = {
  name: "module-manager",
  version: "1",
  tagline: "t",
  verbs: [
    { usage: "list [--json]" },
    { usage: "show <module> [--json]" },
    { usage: "modify <module> --set field=value... [--allow-disruption]", options: [["--set field=value", "A field."], ["--dry-run", "Pre-gate."], ["--allow-disruption", "Reboot it now."]] },
    { usage: "delete <module> [--remove]", effect: { noPreview: "destroys the guest" }, options: [["--remove", "Remove the config."]] },
  ],
};

// site-manager's node add, as the invented tool site_manager_add_node meant it.
const SITE_SPEC: HelpSpec = {
  name: "site-manager",
  version: "1",
  tagline: "t",
  verbs: [
    { usage: "node list [--json]" },
    { usage: "node add <name> [--pxe] [--mac <mac>]", effect: { noPreview: "registers the node and waits for it" }, options: [["--pxe", "Install it over the network."], ["--mac <mac>", "The port that boots."]] },
  ],
};

const me = (over: Partial<Me> = {}): Me => ({ user: "lars", name: "Lars", email: null, groups: ["installer"], role: "installer", via: "gate", route: "console", ...over });
const closed: SetupState = { active: false, identityInstalled: true, tokenPresent: false };

type Chunk = Record<string, unknown>;
// A streamed completion made here: one tool call, or a text answer.
const chunk = (delta: Record<string, unknown>, finish?: string): Chunk => ({ id: "chatcmpl-t", object: "chat.completion.chunk", created: 1, model: "vllm", choices: [{ index: 0, delta, ...(finish ? { finish_reason: finish } : {}) }] });
const callChunks = (id: string, name: string, args: unknown): Chunk[] => [chunk({ role: "assistant", content: "" }), chunk({ tool_calls: [{ index: 0, type: "function", id, function: { name, arguments: JSON.stringify(args) } }] }), chunk({}, "tool_calls")];
const textChunks = (text: string): Chunk[] => [chunk({ role: "assistant", content: text }), chunk({}, "stop")];
const EX = JSON.parse(readFileSync(join(FIX, "litellm-exchange.json"), "utf8")) as { models: unknown; memory: Chunk[][]; runit: Chunk[][]; plain: Chunk[][] };

// The fake LiteLLM: the key it accepts, the request bodies it got, a queue of
// streamed answers (one per completion).
function fakeLiteLLM(): Promise<{ port: number; bodies: { messages: ChatMessage[]; tools: { function: { name: string } }[]; model: string; stream: boolean }[]; queue: Chunk[][]; close: () => void }> {
  const bodies: { messages: ChatMessage[]; tools: { function: { name: string } }[]; model: string; stream: boolean }[] = [];
  const queue: Chunk[][] = [];
  const srv = createServer((req: IncomingMessage, res: ServerResponse) => {
    let text = "";
    req.on("data", (c) => (text += c.toString("utf8")));
    req.on("end", () => {
      if (req.headers["authorization"] !== "Bearer sk-test") {
        res.statusCode = 401;
        res.end('{"error":{"message":"bad key"}}');
        return;
      }
      if (req.url === "/v1/models") {
        res.setHeader("Content-Type", "application/json");
        res.end(JSON.stringify(EX.models));
        return;
      }
      if (req.url === "/v1/chat/completions") {
        bodies.push(JSON.parse(text));
        res.setHeader("Content-Type", "text/event-stream");
        // Written as a stream would arrive: a chunk cut across writes.
        const all = (queue.shift() ?? EX.plain[0]).map((c) => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n";
        const mid = Math.floor(all.length / 2);
        res.write(all.slice(0, mid));
        res.end(all.slice(mid));
        return;
      }
      res.statusCode = 404;
      res.end();
    });
  });
  return new Promise((resolve) => {
    srv.listen(0, "127.0.0.1", () => {
      const a = srv.address() as { port: number };
      resolve({ port: a.port, bodies, queue, close: () => srv.close() });
    });
  });
}

async function main(): Promise<void> {
  // ── the pieces ──────────────────────────────────────────────────────
  check(parseKeyFile("LITELLM_API_KEY=sk-1\nLITELLM_BASE_URL=http://litellm.rossen.internal:4000/v1/\n")?.baseUrl === "http://litellm.rossen.internal:4000/v1", "the key file litellm:models writes is read (base URL without its slash)");
  check(parseKeyFile("LITELLM_API_KEY=\nLITELLM_BASE_URL=http://x:4000/v1") === null && parseKeyFile("LITELLM_API_KEY=k\n") === null, "a key file without a key or an endpoint is no key");
  check(chooseModel(["vllm", "default"], null).model === "default" && chooseModel(["vllm"], null).from === "first listed", "the model: LiteLLM's `default`, else the first listed");
  check(chooseModel(["vllm"], "vllm").from === "console.json" && chooseModel(["vllm"], "gpt").model === null, "console.json's assistantModel wins, and must be offered to the key");
  const deltas: string[] = [];
  const sp = new StreamParser((t) => deltas.push(t));
  const raw = EX.memory[1].map((c) => `data: ${JSON.stringify(c)}\n\n`).join("") + "data: [DONE]\n\n";
  for (let i = 0; i < raw.length; i += 37) sp.feed(raw.slice(i, i + 37)); // cut anywhere, even mid-line
  const parsed = sp.end();
  check(parsed.toolCalls.length === 1 && parsed.toolCalls[0].function.name === "propose_job" && JSON.parse(parsed.toolCalls[0].function.arguments).argv[2] === "immich", "the stream: a tool call assembled from its fragments");
  check(deltas.join("") === parsed.content && parsed.content.startsWith("immich uses") && parsed.finish === "tool_calls" && sp.done, "the stream: text as it comes, the finish reason, [DONE]");
  check(logql("immich", 'say "hi"\\') === '{host="immich"} |= "say \\"hi\\"\\\\"', "a log filter is quoted for LogQL");
  check(timeOf("2h", 10 * 3600_000, 0) === 8 * 3600_000 && timeOf(null, 5, 3) === 3 && timeOf("soon", 1, 0) === null, "times: relative, default, refused");
  check(userKey("lars", "gate") === "lars" && userKey(null, "local") === "local" && userKey("../x", "gate") === "__x", "a user's directory name cannot climb");

  // ── a site, a console, the fake LiteLLM ─────────────────────────────
  const dir = mkdtempSync(join(tmpdir(), "console-assistant-"));
  const ll = await fakeLiteLLM();
  writeFileSync(join(dir, "litellm-svckey.env"), `LITELLM_API_KEY=sk-test\nLITELLM_BASE_URL=http://127.0.0.1:${ll.port}/v1\n`);
  check(lokiConfig(dir, dir, {}) === null, "no logs tool without the logging module");
  writeFileSync(join(dir, "zones.json"), readFileSync(join(FIX, "wizards", "zones.json"), "utf8"));
  const site = fakeSite();
  const reads = new Reads({ configDir: dir, stateDir: join(dir, "state"), run: site.run, journalDays: 7 });
  const ms: Manifests = { byBin: new Map([["module-manager", renderManifest(SPEC)], ["site-manager", renderManifest(SITE_SPEC)]]), errors: [], loadedAt: "" };
  const ran: string[] = [];
  const stream: Streamer = async (bin, args, onOutput) => {
    ran.push([bin, ...args].join(" "));
    onOutput("ok\n");
    return { rc: 0, ran: true, error: null };
  };
  const unit: Runner = async (bin, args) =>
    bin === "systemctl" ? { rc: 0, stdout: "ActiveState=inactive\n", stderr: "", ran: true } : site.run(bin, args);
  let assistant: Assistant | null = null;
  const jobs = new Jobs({ stateDir: join(dir, "state"), configDir: dir, manifests: () => ms, stream, run: unit, proposal: (m, c, p) => assistant?.proposal(m, c, p) ?? null });
  const sudo: string[] = [];
  const llm = new LiteLLM({ keyFile: join(dir, "litellm-svckey.env"), configDir: dir, run: async (b, a) => (sudo.push(`${b} ${a.join(" ")}`), { rc: 1, stdout: "", stderr: "cat: x: No such file or directory", ran: true }) });
  const tools: ToolContext = { reads, manifests: () => ms, jobs: () => jobs.list(), loki: null, repoRoot: dir };
  const store = new Conversations(join(dir, "state", "assistant"));
  assistant = new Assistant({ status: () => llm.status(), chat: llm.chat, tools, store, site: async () => ({ name: "rossen", displayName: "Rossen home" }) });

  const st = await llm.status();
  check(st.available && st.model === "vllm" && st.modelFrom === "first listed" && st.endpoint === `http://127.0.0.1:${ll.port}/v1`, "status: available, LiteLLM's model for the key, the endpoint");
  check(!JSON.stringify(st).includes("sk-test"), "the status never carries the key");

  // ── the mockup's question (spike §5.3, mockup 5) ────────────────────
  ll.queue.push(...EX.memory);
  const ev: AssistantEvent[] = [];
  const t1 = await assistant.chat(me(), { message: "why does immich fail the memory gate?", focus: { page: "module", kind: "module", name: "immich" } }, (e) => ev.push(e));
  check(ev[0]?.type === "conversation" && ev[ev.length - 1]?.type === "done", "a turn streams: conversation first, done last");
  check(ll.bodies.length === 3 && ll.bodies.every((b) => b.model === "vllm" && b.stream === true), "three completions: two rounds of tools, then the answer");
  const sys = ll.bodies[0].messages[0];
  check(sys.role === "system" && /site rossen \(Rossen home\)/.test(sys.content ?? ""), "context: the site's name");
  check(/talking to Lars \(lars\), role Installer/.test(sys.content ?? ""), "context: the operator's name and role");
  check(/In view: module immich on the module page/.test(sys.content ?? ""), "context: the page and the object in view");
  check(/never run, apply or change anything/.test(sys.content ?? "") && /module-manager: list · show <module> · modify <module> --set field=value\.\.\. W · delete <module> D/.test(sys.content ?? ""), "the rule, and the verbs in short form (W, D)");
  const sent = ll.bodies[0].tools.map((t) => t.function.name).sort();
  check(sent.every((n) => (sys.content ?? "").includes(`\n- ${n}(`)) && /No other tool exists/.test(sys.content ?? "") && /There is no tool per manager or per verb/.test(sys.content ?? ""), "the prompt lists every tool sent, by its exact name, and says there is no other");
  check((sys.content ?? "").includes('propose_job({"argv": ["module-manager", "update", "immich"]') && /What propose_job may propose: the managers' verbs/.test(sys.content ?? ""), "a worked propose_job, and the verbs introduced as what it may propose");
  check((sys.content ?? "").includes('open_console({"target": "add-node"})') && (sys.content ?? "").includes("Wizards: add-node (values:") && /modify-module <module>/.test(sys.content ?? "") && /Call propose_job only for a verb the console has no form for/.test(sys.content ?? "") && (sys.content ?? "").includes('open_console({"target": "modify-module immich", "values": {"memory": "10240"}})'), "the prompt: open_console for what the console has a form for, worked, with the wizards");
  check(JSON.stringify(sent) === JSON.stringify(Object.keys(TOOLS).filter((n) => n !== "logs").sort()), "the tools sent are exactly the allow-list (no logs without Loki)");
  check(!sent.some((n) => /apply|run|exec|write|set/.test(n)), "no tool that applies, runs or writes exists");
  check(t1 !== null && t1.steps.map((s) => s.tool).join(",") === "health,module_show,propose_job" && t1.steps.every((s) => s.ok), "the reads, then the proposal");
  const toolMsgs = ll.bodies[1].messages.filter((m) => m.role === "tool");
  check(toolMsgs.length === 2 && /95% of declared/.test(toolMsgs[0].content ?? "") && toolMsgs[0].tool_call_id === "chatcmpl-tool-9b0e6f6d639a4c31", "the model is answered from the real health read, call by call");
  const prop = ev.find((e) => e.type === "proposal");
  const p1 = prop?.type === "proposal" ? prop.proposal : null;
  check(p1 !== null && p1.id === "p1-1" && p1.turn === 1 && p1.argv.join(" ") === "module-manager modify immich --set memory=10240" && !p1.read && p1.preview === "dry-run-flag", "a proposed-job card: the argv, validated against the manifest, previewed by its dry run");
  check(p1?.previewArgv?.join(" ") === "module-manager modify immich --set memory=10240 --dry-run" && p1?.applyArgv.join(" ") === "module-manager modify immich --set memory=10240", "the card knows what its preview and its Run run");
  check(t1?.answer.includes("immich uses 7.6 of its 8.0 GiB") === true && t1?.answer.includes("I put a card up") === true, "the answer, across the rounds");
  check(ran.length === 0 && jobs.list().length === 0, "the turn ran nothing and created no job");
  const convId = ev[0]?.type === "conversation" ? ev[0].id : "";
  const file = join(dir, "state", "assistant", "lars", `${convId}.json`);
  check(((statSync(file) as unknown as { mode: number }).mode & 0o777) === 0o600, "the conversation is a file of the user's, mode 0600, in the state dir");
  check(sudo.length === 0, "a readable key file is read without sudo");

  // ── T5: asked to run it, it proposes and applies nothing ────────────
  ll.queue.push(...EX.runit);
  const ev2: AssistantEvent[] = [];
  const t2 = await assistant.chat(me(), { conversation: convId, message: "ok, run it" }, (e) => ev2.push(e));
  check(t2 !== null && t2.steps.filter((s) => s.refused).map((s) => s.tool).join(",") === "apply_job,module_manager_modify", "the model's apply and write calls are refused (T5)");
  const refusedMsg = ll.bodies[ll.bodies.length - 1].messages.filter((m) => m.role === "tool").slice(-2);
  check(refusedMsg.every((m) => /^Refused: there is no tool/.test(m.content ?? "")), "the model is told: no such tool, the operator's Run does it");
  check(/the Run button on the card does/.test(t2?.answer ?? ""), "it answers that the Run button does it, and why");
  check(ran.length === 0 && jobs.list().length === 0, "nothing was applied, no job exists (T5)");
  check(ll.bodies[ll.bodies.length - 2].messages.filter((m) => m.role === "user").length === 2, "the second turn carries the first as history");
  const saved = store.get("lars", convId);
  check(saved !== null && saved.turns.length === 2 && saved.turns[1].steps.some((s) => s.refused === true), "the refusal is in the conversation's record");

  // ── the card's job carries the turn (T5) ────────────────────────────
  const ref = { conversation: convId, proposal: "p1-1" };
  let r = await jobs.create(me(), closed, { argv: p1!.argv, preview: true, assistant: ref });
  check(r.status === 201 && r.job?.origin === "assistant" && r.job.assistant?.turn === 1 && r.job.assistant.proposal === "p1-1" && r.job.assistant.conversation === convId, "the card's preview is a job from the assistant, with its conversation and turn");
  for (let i = 0; i < 20 && jobs.get(r.job!.id)?.state !== "done"; i++) await new Promise<void>((res) => setTimeout(res, 2));
  check(ran.length === 1 && ran[0] === "module-manager modify immich --set memory=10240 --dry-run", "only the operator's Preview ran: the dry run");
  const a = await jobs.applyPreview(me(), closed, r.job!.id, {});
  check(a.status === 201 && a.job?.origin === "assistant" && a.job.assistant?.proposal === "p1-1", "its Run (the operator's click) carries the turn too");
  for (let i = 0; i < 20 && jobs.get(a.job!.id)?.state !== "done"; i++) await new Promise<void>((res) => setTimeout(res, 2));
  r = await jobs.create(me(), closed, { argv: ["module-manager", "modify", "immich", "--set", "memory=16384"], preview: true, assistant: ref });
  check(r.status === 400 && /not the one proposal p1-1 proposed/.test(r.error ?? ""), "a card's job must be the argv it proposed");
  r = await jobs.create(me({ user: "eve", name: "Eve" }), closed, { argv: p1!.argv, preview: true, assistant: ref });
  check(r.status === 400 && /no proposal/.test(r.error ?? ""), "another user cannot claim someone's card");
  const jl = readFileSync(join(dir, "state", "jobs.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l) as { origin: string; assistant: unknown });
  check(jl.length >= 2 && jl.every((j) => j.origin === "assistant" && j.assistant !== null), "Activity's record says where the jobs came from");

  // ── the allow-list and propose_job, one call at a time ──────────────
  let o = await runTool(tools, "module_modify", '{"module":"immich"}');
  check(!o.ok && o.refused === true, "an unknown tool is refused");
  o = await runTool(tools, "logs", '{"host":"immich"}');
  check(o.refused === true, "the logs tool does not exist without Loki");
  o = await runTool(tools, "propose_job", JSON.stringify({ argv: ["module-manager", "modify", "immich", "--set", "memory=10240", "--apply"], rationale: "x" }));
  check(!o.ok && !o.proposal && /Leave out --apply/.test(o.content), "a proposal never carries the applying flag");
  o = await runTool(tools, "propose_job", JSON.stringify({ argv: ["module-manager", "frob", "immich"], rationale: "x" }));
  check(!o.ok && !o.proposal && /not a verb/.test(o.content), "a verb no manifest declares is not proposed");
  o = await runTool(tools, "propose_job", JSON.stringify({ argv: ["rm", "-rf", "/"], rationale: "x" }));
  check(!o.ok && !o.proposal, "a command that is not a manager is not proposed");
  o = await runTool(tools, "propose_job", JSON.stringify({ argv: ["module-manager", "delete", "immich"], rationale: "x" }));
  check(o.ok && o.proposal?.destructive === true && o.proposal.previewArgv === null && /Installer only/.test(o.content), "a destructive proposal says so");
  o = await runTool(tools, "propose_job", JSON.stringify({ argv: ["module-manager", "show", "immich"], rationale: "x" }));
  check(o.ok && o.proposal?.read === true && o.proposal.previewArgv === null, "a read is proposed as a read");
  check(/preview:  module-manager modify immich --set memory=10240 --dry-run\n  apply:    module-manager modify immich --set memory=10240/.test(proposalText({ ...p1!, previewArgv: p1!.previewArgv, applyArgv: p1!.applyArgv })), "tappaas ask prints a proposal as its preview and apply, not run");
  o = await runTool(tools, "health", '{"gate":"guest-memory"}');
  check(o.ok && /"name":"guest-memory"/.test(o.content) && o.content.length <= 7100, "a read answers from the console's cache, capped");
  o = await runTool(tools, "topology", "{}");
  check(o.ok && /tappaas1/.test(o.content) && /immich\(361/.test(o.content), "the topology, compacted");
  o = await runTool(tools, "module_show", '{"module":"../etc"}');
  check(!o.ok && /module's name/.test(o.content), "a tool's module argument is checked like a route's");

  // ── an invented tool: refused with the call it meant, then recovered ─
  check(JSON.stringify(guessArgv(ms, "site_manager_add_node", '{"name":"tappaas3"}')) === '["site-manager","node","add","tappaas3"]', "an invented tool's name read as manager and verb, either word order");
  check(JSON.stringify(guessArgv(ms, "module_manager_modify", '{"module":"immich","memory":10240}')) === '["module-manager","modify","immich","--set","memory=10240"]', "…a field as --set field=value");
  check(JSON.stringify(guessArgv(ms, "site_manager_add_node", "{}")) === '["site-manager","node","add","<name>"]' && guessArgv(ms, "apply_job", "{}") === null, "…a missing positional as <name>; no guess for a name that is no manager");
  const before = { jobs: jobs.list().length, ran: ran.length };
  ll.queue.push(
    callChunks("c-inv", "site_manager_add_node", { name: "tappaas3" }),
    callChunks("c-ok", "propose_job", { argv: ["site-manager", "node", "add", "tappaas3", "--pxe"], rationale: "a third node, installed over the network" }),
    textChunks("I put a card up to add tappaas3; its Run starts the install."),
  );
  const ev3: AssistantEvent[] = [];
  const t3 = await assistant.chat(me(), { message: "want to add a node" }, (e) => ev3.push(e));
  check(t3 !== null && t3.steps.map((s) => `${s.tool}:${s.refused ? "refused" : s.ok}`).join(",") === "site_manager_add_node:refused,propose_job:true", "an invented tool is refused, then the model proposes the verb");
  const told = ll.bodies[ll.bodies.length - 2].messages.filter((m) => m.role === "tool").pop()?.content ?? "";
  check(/^Refused: there is no tool 'site_manager_add_node'/.test(told) && /no tool per manager or per verb/.test(told) && /call propose_job with the command as an array/.test(told) && /call help/.test(told), "the refusal names the tools to use instead: propose_job, and help to look a verb up");
  check(told.includes('propose_job({"argv": ["site-manager","node","add","tappaas3"]'), "…and spells out the propose_job call it probably meant");
  check(told.includes('open_console({"target":"add-node","values":{"name":"tappaas3"}})') && /open_console/.test(told.split("\n")[0]), "…and, the console having a form for it, the open_console call");
  const p3 = ev3.find((e) => e.type === "proposal");
  check(p3?.type === "proposal" && p3.proposal.argv.join(" ") === "site-manager node add tappaas3 --pxe" && p3.proposal.preview === "none", "the recovered call is a card");
  check(jobs.list().length === before.jobs && ran.length === before.ran, "and nothing ran");

  // ── open_console: a page or a wizard, filled in, nothing changed ───
  o = await runTool(tools, "open_console", '{"target":"add-node"}');
  check(o.ok && o.navigate?.path === "/setup/day2" && o.navigate.title === "the Add node wizard" && o.navigate.url === "https://console.hrossen.dk/setup/day2" && /Nothing changed/.test(o.content), "open_console add-node: Day 2, its address under the console's domain, nothing changed");
  o = await runTool({ ...tools, shell: true }, "open_console", '{"target":"add-node"}');
  check(o.ok && /in a shell \(tappaas ask\): they were given the address of the Add node wizard, https:\/\/console\.hrossen\.dk\/setup\/day2/.test(o.content), "from tappaas ask the model is told the operator got the address");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "modify-module immich", values: { memory: 10240 } }));
  check(o.ok && o.navigate?.path === "/modules/immich" && o.navigate.title === "Modify immich" && JSON.stringify(o.navigate.values) === '{"memory":"10240"}', "modify-module immich with memory: the module's page, the value as the form's text");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "modify-module immich", values: { ram: "10240" } }));
  check(!o.ok && !o.navigate && /immich has no field ram \(its fields: memory\)/.test(o.content), "a field the module does not have is refused, with its fields");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "modify-module plex" }));
  check(!o.ok && /no deployed module 'plex'/.test(o.content), "a module that is not deployed is refused");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "add-wifi", values: { zone: "home", ssid: "rossen-home" } }));
  check(o.ok && o.navigate?.target === "add-wifi home" && o.navigate.path === "/setup/day2#wifi-home" && JSON.stringify(o.navigate.values) === '{"ssid":"rossen-home"}', "add-wifi takes its zone after the name or as a value");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "add-wifi work" }));
  check(!o.ok && /active Client and Guest zones; work is Client, Inactive/.test(o.content), "WiFi only for an active Client or Guest zone");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "modify-zone home", values: { description: "x" } }));
  check(o.ok && o.navigate?.path === "/environments?zone=home", "modify-zone opens the zone on Environments");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "/site/physical" }));
  check(o.ok && o.navigate?.title.startsWith("the physical view") === true && o.navigate.values !== undefined, "a page");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "/security" }));
  check(!o.ok && /no page \/security/.test(o.content), "a page the console does not have is refused");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "add-vm" }));
  check(!o.ok && /no wizard 'add-vm' \(wizards: add-node,/.test(o.content), "a wizard the console does not have is refused, with the list");
  o = await runTool(tools, "open_console", JSON.stringify({ target: "add-node", values: { cores: "4" } }));
  check(!o.ok && /add-node has no cores: its values are name/.test(o.content), "a value a wizard does not take is refused");
  check(JSON.stringify(consoleFormFor(ms, ["module-manager", "modify", "immich", "--set", "memory=10240"])) === '{"target":"modify-module immich","values":{"memory":"10240"}}' && consoleFormFor(ms, ["module-manager", "show", "immich"]) === null, "the console's form for a command: its wizard, object and fields; none for a read");

  // ── asked to add a node: the invented tool, then the wizard opened ──
  const before4 = { jobs: jobs.list().length, ran: ran.length };
  ll.queue.push(
    callChunks("c-inv2", "site_manager_add_node", {}),
    callChunks("c-open", "open_console", { target: "add-node" }),
    textChunks("The Add node wizard is open on Setup, Day 2."),
  );
  const ev4: AssistantEvent[] = [];
  const t4 = await assistant.chat(me(), { message: "want to add a node", focus: { page: "overview" } }, (e) => ev4.push(e));
  check(t4 !== null && t4.steps.map((s) => `${s.tool}:${s.refused ? "refused" : s.ok}`).join(",") === "site_manager_add_node:refused,open_console:true", "refused, then open_console");
  const nav = ev4.find((e) => e.type === "navigate");
  check(nav?.type === "navigate" && nav.target === "add-node" && nav.path === "/setup/day2" && nav.title === "the Add node wizard", "a navigate event on the stream: the target, its route, its title");
  check(t4?.opened?.length === 1 && t4.opened[0].target === "add-node" && t4.proposals.length === 0, "the turn records what it opened, and proposes nothing");
  const conv4 = ev4[0]?.type === "conversation" ? ev4[0].id : "";
  check(store.get("lars", conv4)?.turns[0].opened?.[0]?.path === "/setup/day2", "…in the conversation's record");
  check(jobs.list().length === before4.jobs && ran.length === before4.ran, "opening a wizard ran nothing");
  check(/In the console: the Add node wizard — https:\/\/console\.hrossen\.dk\/setup\/day2/.test(openedText(t4!.opened![0])) && /filled in: memory=10240/.test(openedText({ target: "modify-module immich", values: { memory: "10240" }, path: "/modules/immich", title: "Modify immich", url: null })), "tappaas ask prints it as the console's address, with its values");

  // ── a call written as text (hrossen's model after a read) is taken ──
  check(JSON.stringify(writtenCalls('Opening it:\n```json\nopen_console({"target": "modify-module immich", "values": {"memory": "10240"}})\n```', ["open_console", "propose_job"])) === '[{"name":"open_console","arguments":"{\\"target\\":\\"modify-module immich\\",\\"values\\":{\\"memory\\":\\"10240\\"}}"}]', "a call written as name({...}) in a fence");
  check(writtenCalls('```json\n{"argv": ["module-manager", "update", "immich"], "rationale": "x"}\n```', ["propose_job"])[0]?.name === "propose_job" && writtenCalls('```json\n{"memory": 10240}\n```', ["open_console", "propose_job"]).length === 0, "…or a bare object shaped as its arguments; any other JSON is no call");
  check(writtenCalls("I could open_console for you, or propose_job.", ["open_console", "propose_job"]).length === 0 && writtenCalls('apply_job({"p": 1})', ["open_console"]).length === 0, "…a name without arguments, or a tool not offered, is none");
  ll.queue.push(
    callChunks("c-show", "module_show", { module: "immich" }),
    textChunks('immich has 8192 MiB. Opening the form:\n```json\nopen_console({"target": "modify-module immich", "values": {"memory": "10240"}})\n```'),
    textChunks("The Modify form of immich is open with memory 10240 MiB."),
  );
  const ev5: AssistantEvent[] = [];
  const t5 = await assistant.chat(me(), { message: "change immich's memory to 10 GiB" }, (e) => ev5.push(e));
  check(t5 !== null && t5.steps.map((s) => `${s.tool}${s.written ? ":written" : ""}`).join(",") === "module_show,open_console:written" && t5.opened?.[0]?.target === "modify-module immich", "the written call is made, marked as written, and the form opened");
  check(ev5.some((e) => e.type === "navigate" && e.values.memory === "10240") && /Modify form of immich is open/.test(t5?.answer ?? ""), "the navigate event, then the model's answer from the result");
  const last5 = ll.bodies[ll.bodies.length - 1].messages;
  check(last5[last5.length - 2]?.tool_calls?.[0]?.function.name === "open_console" && last5[last5.length - 1]?.role === "tool", "the model is sent its written call as made, with its result");
  check((ll.bodies[ll.bodies.length - 2].messages.filter((m) => m.role === "tool").pop()?.content ?? "").endsWith('call open_console({"target": "modify-module immich", "values": {"<field>": "<value>"}}) now; it changes nothing until the operator applies it.'), "module_show's result ends with the open_console call for a change");

  // ── the logs tool, through Loki's API ───────────────────────────────
  writeFileSync(join(dir, "logging.json"), "{}");
  writeFileSync(join(dir, ".loki-admin-password"), "pw\n");
  const lk = lokiConfig(dir, dir, {});
  let asked = "";
  let auth = "";
  const lokiFetch = (async (url: string, init?: { headers?: Record<string, string> }) => {
    asked = url;
    auth = init?.headers?.Authorization ?? "";
    return { ok: true, status: 200, text: async () => "", json: async () => ({ data: { result: [{ stream: { unit: "immich-ml" }, values: [["1792300000000000000", "OOM pressure"]] }] } }), body: null };
  }) as unknown as typeof fetch;
  o = await runTool({ ...tools, loki: lk, fetch: lokiFetch, now: () => 1792310000000 }, "logs", '{"host":"immich","since":"4h","contains":"OOM"}');
  check(lk !== null && o.ok && /immich-ml: OOM pressure/.test(o.content) && /query_range\?query=%7Bhost%3D%22immich%22%7D/.test(asked) && auth === `Basic ${Buffer.from("tappaas:pw").toString("base64")}`, "logs: Loki's query_range for the host, with the admin credential");
  check(toolDefs({ ...tools, loki: lk }).some((t) => t.function.name === "logs"), "with logging installed the logs tool is offered");

  // ── the history the model is sent ───────────────────────────────────
  const hist: ChatMessage[] = [];
  for (let i = 0; i < 6; i++) hist.push({ role: "user", content: `q${i}` }, { role: "assistant", content: null, tool_calls: [{ id: `c${i}`, type: "function", function: { name: "health", arguments: "{}" } }] }, { role: "tool", tool_call_id: `c${i}`, content: "x".repeat(5000) }, { role: "assistant", content: `a${i}` });
  const h = historyFor(hist, 20, 3000);
  check(h[0].role === "user" && h[0].content === "q5" && h.length === 4, "an old history goes turn by turn; the current turn stays whole");
  const h2 = historyFor(hist, 20, 1_000_000);
  check(h2.length === 24 && (h2[2].content ?? "").length < 1300 && (h2[22].content ?? "").length === 5000, "earlier tool results are shortened; the current turn's are not");
  check(shortManifest(null).includes("help(manager)"), "before the manifests load, the prompt points at help");

  // ── the store's caps ────────────────────────────────────────────────
  let now = Date.parse("2026-10-18T10:00:00Z");
  const small = new Conversations(join(dir, "caps"), { perUser: 2, turns: 3, bytes: 4000 }, () => (now += 1000));
  const ids: string[] = [];
  for (let i = 0; i < 3; i++) {
    const c = small.create("lars");
    c.turns.push({ n: 1, at: "", question: `q${i}`, focus: null, steps: [], answer: "", proposals: [], model: null, error: null });
    small.save(c);
    ids.push(c.id);
  }
  check(small.list("lars").length === 2 && small.get("lars", ids[0]) === null && small.get("lars", ids[2]) !== null, "the newest conversations stay (per user)");
  const big = small.get("lars", ids[2])!;
  for (let i = 2; i <= 6; i++) big.turns.push({ n: i, at: "", question: `q${i}`, focus: null, steps: [], answer: "y".repeat(600), proposals: [], model: null, error: null });
  for (let i = 0; i < 10; i++) big.messages.push({ role: "user", content: "z".repeat(400) }, { role: "assistant", content: "w".repeat(400) });
  small.save(big);
  const capped = small.get("lars", ids[2])!;
  check(capped.turns.length <= 3 && JSON.stringify(capped).length <= 4000 && capped.messages[0].role === "user", "a conversation is capped by turns and size; its history still starts with a question");
  check(small.get("eve", ids[2]) === null && small.get("lars", "../../etc/passwd") === null, "another user's id, or a path, finds nothing");

  // ── the routes ──────────────────────────────────────────────────────
  const access: AccessConfig = { firewall: ["10.0.0.1"], allow: ["127.0.0.1"], setupAllow: [], tokenFile: join(dir, "no-token"), identityFile: join(dir, "identity.json"), trustLocalHeaders: false };
  const srv = new ConsoleServer({ access, webDir: null, mgmtDomain: "mgmt.internal", version: "test", log: () => undefined, litellm: llm, assistant }, reads, jobs);
  const call = async (method: string, url: string, headers: Record<string, string> = {}, peer = "127.0.0.1"): Promise<{ status: number; json: () => { data?: unknown; error?: string } }> => {
    let body = "";
    const res = { statusCode: 200, headersSent: false, setHeader: () => undefined, write: () => true, on: () => undefined, end(d?: string) { body = d ?? ""; } };
    const req = { method, url, headers: { host: "console.hrossen.dk", ...headers }, socket: { remoteAddress: peer, destroy: () => undefined }, on: () => undefined };
    await srv.handle(req as unknown as IncomingMessage, res as unknown as ServerResponse);
    return { status: res.statusCode, json: () => JSON.parse(body) };
  };
  const gate = (host = "console.hrossen.dk") => ({ host, "x-authentik-username": "lars", "x-authentik-groups": "installer" });
  let c = await call("GET", "/api/v1/assistant/status");
  check(c.status === 200 && (c.json().data as { available: boolean }).available === true, "GET /assistant/status: available");
  c = await call("GET", "/api/v1/assistant/status", gate("status.hrossen.dk"), "10.0.0.1");
  check((c.json().data as { available: boolean }).available === false, "the owner's view has no assistant");
  c = await call("POST", "/api/v1/assistant/chat", gate("status.hrossen.dk"), "10.0.0.1");
  check(c.status === 403, "and cannot ask it");
  c = await call("POST", "/api/v1/assistant/chat", { "content-type": "text/plain" });
  check(c.status === 415, "a question is posted as JSON");
  c = await call("GET", "/api/v1/assistant/conversations", gate(), "10.0.0.1");
  check(c.status === 200 && (c.json().data as { id: string }[]).some((x) => x.id === convId), "the caller's own conversations");
  c = await call("GET", "/api/v1/assistant/conversations");
  check((c.json().data as unknown[]).length === 0, "loopback sees only its own (none yet)");
  c = await call("GET", `/api/v1/assistant/conversations/${convId}`, gate(), "10.0.0.1");
  check(c.status === 200 && (c.json().data as { turns: unknown[]; messages?: unknown }).turns.length === 2 && (c.json().data as { messages?: unknown }).messages === undefined, "one conversation: its turns, not the raw messages");

  // ── end to end over HTTP: tappaas ask's path (loopback, read) ───────
  const http = await srv.listen("127.0.0.1", 0);
  const port = (http.address() as { port: number }).port;
  ll.queue.push(...EX.plain);
  const got: string[] = [];
  const p = sseEvents((e) => got.push(e.type));
  const resp = await fetch(`http://127.0.0.1:${port}/api/v1/assistant/chat`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ message: "how is the site?", focus: { page: "shell" } }) });
  const dec = new TextDecoder();
  for await (const part of resp.body!) p.feed(dec.decode(part, { stream: true }));
  check(got[0] === "conversation" && got.includes("delta") && got[got.length - 1] === "done", "POST /assistant/chat streams server-sent events end to end");
  check(/the operator in a shell on tappaas-cicd/.test(ll.bodies[ll.bodies.length - 1].messages[0].content ?? "") && /role read only/.test(ll.bodies[ll.bodies.length - 1].messages[0].content ?? ""), "from loopback: the shell's operator, the read role");
  check(store.list("local").length === 1, "and its conversation is the local user's");
  srv.close();
  ll.close();

  // ── without a key ───────────────────────────────────────────────────
  const none = new LiteLLM({ keyFile: join(dir, "absent.env"), configDir: dir, run: async () => ({ rc: 1, stdout: "", stderr: "cat: /x: No such file or directory", ran: true }) });
  const s0 = await none.status();
  check(!s0.available && /AI stack is not installed/.test(s0.reason), "no key and no litellm module: not installed");
  writeFileSync(join(dir, "litellm.json"), "{}");
  const s1 = await none.status(true);
  check(!s1.available && /module-manager update console/.test(s1.reason), "the stack without the console's key: how to wire it");
  const eva: AssistantEvent[] = [];
  await new Assistant({ status: () => none.status(), chat: none.chat, tools, store, site: async () => ({ name: "rossen", displayName: null }) }).chat(me(), { message: "hi" }, (e) => eva.push(e));
  check(eva.length === 1 && eva[0].type === "error" && /not available/.test((eva[0] as { message: string }).message), "without the AI stack a question gets the reason, nothing else");

  done("assistant");
}

void main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
