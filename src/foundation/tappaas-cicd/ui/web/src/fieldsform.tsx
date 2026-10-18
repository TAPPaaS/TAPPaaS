// fieldsform.tsx — a change class as a tag: its meaning, always in the one
// muted colour, the technical name only on hover (the field forms are fields.tsx).

import { CLASS_WORDS, classMeaning, classTitle } from "./forms";

export const CLASS_TEXT = CLASS_WORDS;

export function ClassTag({ c, apply, why }: { c: string | null; apply?: string | null; why?: string | null }) {
  const words = classMeaning(c, apply);
  return words ? <span className="class-tag" title={classTitle(c, apply, why)}>{words}</span> : null;
}
