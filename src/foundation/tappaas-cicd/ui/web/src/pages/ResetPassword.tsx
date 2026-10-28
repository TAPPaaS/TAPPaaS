// ResetPassword.tsx — Day 2's "Reset a user's password", also the identity
// page's button on a user: a person who cannot sign in gets a new way in. 1 the
// user; 2 one of two ways — a one-time link the user opens to set a password
// of their own (identity-manager user reset-password, Authentik's recovery
// flow), or a temporary password typed here twice and set through the secrets
// endpoint (identity-manager … --password-stdin: never in a command, never
// kept); 3 what to hand the user.

import { useMemo, useState } from "react";
import { post, useRead } from "../api";
import { Job } from "../types";
import { stripAnsi } from "../jobs";
import { Step, StepView } from "../operate";
import { useOpenedBy } from "../opener";
import { Dot, canOperate, useMe } from "../ui";
import { SecretStatus, StepRow } from "./Setup";

// What the activity is, on Day 2's card and at the top of the form.
export const RESET_PASSWORD_TEXT = "Gives a user who cannot sign in a new way in: a one-time link where they set a password of their own, or a temporary password you hand over.";

// The link in the verb's output: the first https URL.
export function linkOf(output: string): string | null {
  return /https?:\/\/\S+/.exec(stripAnsi(output))?.[0] ?? null;
}

type Way = "link" | "password";

export function ResetPasswordWizard({ onClose, user: preset }: { onClose: () => void; user?: string | null }) {
  const me = useMe();
  const users = useRead<Record<string, string[]>>("identity").env?.data?.user ?? [];
  const [user, setUser] = useState(preset ?? "");
  const [way, setWay] = useState<Way>("link");
  const [pw1, setPw1] = useState("");
  const [pw2, setPw2] = useState("");
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<string | null>(null);
  const [done, setDone] = useState<{ way: Way; link: string | null } | null>(null);
  const pwProblem = pw1.length < 8 ? "8 characters or more" : pw1 !== pw2 ? "the two do not match" : !/^[\x20-\x7e]+$/.test(pw1) ? "printable characters only" : null;
  const chosen = users.includes(user) ? user : "";

  const link: Step = useMemo(
    () => ({
      title: `identity-manager user reset-password ${chosen || "<user>"} --link`,
      bin: "identity-manager",
      verb: "user reset-password",
      words: ["user", "reset-password"],
      fixed: chosen ? [chosen, "--link"] : [],
      only: [],
      hide: ["@name"],
      blocked: chosen ? undefined : "pick the user first",
      note: "Asks Authentik for a one-time link. Whoever opens it sets the password of this user, so hand it to them the way you would a key. It expires unused. There is no dry run: the preview is the command.",
      after: (j: Job) => {
        const l = linkOf(j.output);
        return l ? (
          <p className="small">
            <b>The link</b> <span className="mono">{l}</span> <button className="btn" onClick={() => void navigator.clipboard?.writeText(l)}>Copy</button>
          </p>
        ) : null;
      },
    }),
    [chosen],
  );

  const setPassword = async () => {
    setBusy(true);
    setMsg(null);
    const r = await post<SecretStatus>("secrets/user-password", { user: chosen, password: pw1 });
    setBusy(false);
    setPw1("");
    setPw2("");
    if (!r.ok) return setMsg(r.error);
    setDone({ way: "password", link: null });
  };

  const stages = [
    { id: "user", title: "1 · The user", required: true, done: chosen ? true : false, detail: "Who cannot sign in." },
    { id: "way", title: "2 · The new way in", required: true, done: done ? true : chosen ? null : false, detail: "A one-time link they open to set their own password, or a temporary password you choose and hand over." },
    { id: "tell", title: "3 · Tell the user", required: false, done: done ? true : null, detail: "What to pass on, and how." },
  ];
  const current = !chosen ? "user" : !done ? "way" : "tell";

  return (
    <div className="modal-back" onClick={onClose}>
      <div className="modal modal-wide" onClick={(e) => e.stopPropagation()} role="dialog" aria-label="Reset a user's password">
        <header className="modal-head">
          <h2>Reset a user's password</h2>
          <button className="btn-x" onClick={onClose} aria-label="close">×</button>
        </header>
        <p className="small">{RESET_PASSWORD_TEXT}</p>
        <ol className="setup">
          <StepRow s={stages[0]} open={current === "user"}>
            <div className="form">
              <label className="form-row">
                <span>user *</span>
                <select value={chosen} disabled={done !== null} onChange={(e) => setUser(e.target.value)}>
                  <option value="">{users.length ? "— pick the user" : "— reading the users…"}</option>
                  {users.map((u) => (
                    <option key={u} value={u}>{u}</option>
                  ))}
                </select>
                <small className="muted">The users identity-manager knows; a person not listed is added first (Day 2, Add a user).</small>
              </label>
            </div>
          </StepRow>
          <StepRow s={stages[1]} open={current === "way"}>
            {!chosen ? (
              <p className="muted small">Once the user is picked.</p>
            ) : (
              <>
                <div className="form">
                  <label className="form-check">
                    <input type="radio" name="way" checked={way === "link"} disabled={done !== null} onChange={() => setWay("link")} />
                    <span>a one-time link</span> <small className="muted">The user sets a password of their own. Preferred: you never know it.</small>
                  </label>
                  <label className="form-check">
                    <input type="radio" name="way" checked={way === "password"} disabled={done !== null} onChange={() => setWay("password")} />
                    <span>a temporary password</span> <small className="muted">You choose it and hand it over; the user changes it after signing in.</small>
                  </label>
                </div>
                {way === "link" ? (
                  <StepView key={chosen} step={link} me={me} onDone={(ok) => ok && setDone({ way: "link", link: null })} />
                ) : (
                  <div className="form">
                    <label className="form-row">
                      <span>password *</span>
                      <input type="password" autoComplete="new-password" placeholder="8 characters or more" value={pw1} disabled={busy || done !== null} onChange={(e) => setPw1(e.target.value)} />
                    </label>
                    <label className="form-row">
                      <span>again *</span>
                      <input type="password" autoComplete="new-password" value={pw2} disabled={busy || done !== null} onChange={(e) => setPw2(e.target.value)} />
                      <small className="muted">{pw1 && pwProblem ? <span className="ff-error">{pwProblem}. </span> : null}Set in Authentik through identity-manager with the password on its stdin: never in a command, never kept by the console.</small>
                    </label>
                    <div className="actions">
                      <button className="btn btn-primary" disabled={busy || done !== null || pwProblem !== null || !canOperate(me)} onClick={() => void setPassword()}>
                        {busy ? "Setting…" : `Set the password of ${chosen}`}
                      </button>
                      <span className="muted small">identity-manager user reset-password {chosen} --password-stdin</span>
                    </div>
                    {msg ? <p className="readstate readstate-fail">{msg}</p> : null}
                    {done?.way === "password" ? <p className="small"><Dot level="pass" /> The password of {chosen} is set.</p> : null}
                  </div>
                )}
              </>
            )}
          </StepRow>
          <StepRow s={stages[2]} open={current === "tell"}>
            {!done ? (
              <p className="muted small">Once the new way in exists.</p>
            ) : done.way === "link" ? (
              <ol>
                <li>Send the link from stage 2 to {chosen} by a way you trust: it is the key to their account until it is used or expires.</li>
                <li>They open it, set a password of their own, and sign in as before. Their other sessions are not signed out.</li>
              </ol>
            ) : (
              <ol>
                <li>Hand the password to {chosen} apart from the sign-in address: by voice, or a message that is not the one with the link.</li>
                <li>They sign in with it and change it at once in their account settings.</li>
              </ol>
            )}
          </StepRow>
        </ol>
      </div>
    </div>
  );
}

// The button on a user (the identity page): the user preset.
export function ResetPasswordButton({ user, small }: { user?: string; small?: boolean }) {
  const [open, setOpen] = useState<string | null | false>(false);
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(user ?? null)}>{small ? "Reset password…" : "Reset a user's password…"}</button>
      {open !== false ? <ResetPasswordWizard onClose={() => setOpen(false)} user={open} /> : null}
    </>
  );
}

// Day 2's card: the wizard the assistant opens too (open_console reset-password).
export function ResetPasswordCardButton() {
  const [open, setOpen] = useState<string | null | false>(false);
  useOpenedBy("reset-password", undefined, (v) => setOpen(typeof v.user === "string" ? v.user : null));
  if (!canOperate(useMe())) return null;
  return (
    <>
      <button className="btn" onClick={() => setOpen(null)}>Reset a user's password…</button>
      {open !== false ? <ResetPasswordWizard onClose={() => setOpen(false)} user={open} /> : null}
    </>
  );
}
