import { config } from "./config.js";
import type { Meter } from "./meter.js";
import { outputText, respond } from "./search.js";

/**
 * Write with AI and Polish with AI, for a registration question that wants a sentence or a paragraph.
 * The app sends the question, what the event is about, the person's saved answers and, to polish,
 * their own notes. The answer is first person, fits the event, and never claims anything the person
 * didn't say.
 */
export interface DraftInput {
  question: string;
  event?: string;
  about?: string;
  notes?: string;
  profile: { label: string; value: string }[];
}

const str = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

export function parseDraft(body: any): DraftInput | null {
  const question = str(body?.question, 600);
  if (!question) return null;
  const profile = (Array.isArray(body?.profile) ? body.profile : [])
    .slice(0, 25)
    .map((p: any) => ({ label: str(p?.label, 200), value: str(p?.value, 600) }))
    .filter((p: { label: string; value: string }) => p.label && p.value);
  return {
    question,
    event: str(body?.event, 200) || undefined,
    about: str(body?.about, 6000) || undefined,
    notes: str(body?.notes, 2000) || undefined,
    profile,
  };
}

export function draftPrompt(input: DraftInput): string {
  const facts = input.profile.map((p) => `- ${p.label}: ${p.value}`).join("\n") || "(none saved)";
  const task = input.notes
    ? `Rewrite their notes into a clear, natural answer. Keep every fact in the notes; add no new claims.`
    : `Write the answer from what you know about them below. Use only those facts.`;
  return `You are filling in an event registration form for someone, in their own voice (first person).

Event: ${input.event ?? "(unknown)"}
What the event is about:
${input.about ?? "(no description)"}

The question on the form:
${input.question}

What we know about the person (their saved answers):
${facts}
${input.notes ? `\nTheir notes for this answer:\n${input.notes}\n` : ""}
${task}
Rules:
- Read what the event is about and answer in a way that fits it: the angle the organizers care about (team matching, a
  talk's topic, why they want to come). Mention what in their background is most relevant to this event.
- Never invent experience, employers, schools, projects, numbers or skills. If something the question asks about isn't
  known, say so briefly and honestly (for example "I'm new to robotics hardware") rather than making it up.
- Respect any length the question sets ("3-4 sentences", "under 100 words"); otherwise 2 to 4 sentences.
- Plain text only: no quotes around it, no markdown, no greeting, no sign-off.

Reply with the answer and nothing else.`;
}

export async function draft(input: DraftInput, meter: Meter): Promise<string> {
  const json = await respond({ model: config.model, input: draftPrompt(input), reasoning: { effort: "low" } }, meter);
  return outputText(json).trim().replace(/^"(.*)"$/s, "$1");
}

// MARK: Replies from a screenshot

/**
 * Share a screenshot of any chat, form or post, and Doorlist writes what the person would answer, in their voice,
 * from their saved answers. A hint ("say I'm free tomorrow at 3") steers it or rewrites the last version.
 */
export interface ReplyInput {
  image: string;
  hint?: string;
  previous?: string;
  profile: { label: string; value: string }[];
}

export function parseReply(body: any): ReplyInput | null {
  const image = typeof body?.image === "string" ? body.image : "";
  // A base64 JPEG or PNG, up to about 3 MB.
  if (!/^[A-Za-z0-9+/=]{100,4000000}$/.test(image)) return null;
  const base = parseDraft({ question: "reply", profile: body?.profile });
  return { image, hint: str(body?.hint, 600) || undefined, previous: str(body?.previous, 3000) || undefined, profile: base!.profile };
}

export function replyPrompt(input: ReplyInput): string {
  const facts = input.profile.map((p) => `- ${p.label}: ${p.value}`).join("\n") || "(none saved)";
  return `The image is a screenshot from the person's phone: a chat, an email, a post, or a form.

Work out what they'd want to send next: the reply to the latest message addressed to them, or the answer to the
question or field on screen. Then write it in their own voice (first person), matching the tone of the conversation
(casual chat stays casual and short; a form or email can be fuller).

What we know about the person (their saved answers):
${facts}
${input.previous ? `\nThe last version you wrote:\n${input.previous}\n` : ""}${input.hint ? `\nTheir instructions for this reply (follow these first):\n${input.hint}\n` : ""}
Rules:
- Never invent facts about them, plans, times or commitments they didn't give. If the reply needs something you don't
  know (when they're free, a number), keep it open ("what times work for you?") rather than making it up.
- Use their background only where it helps the reply.
- Plain text only, ready to paste: no quotes around it, no markdown, no explanation.

Reply with the message and nothing else.`;
}

export async function reply(input: ReplyInput, meter: Meter): Promise<string> {
  const mime = input.image.startsWith("iVBOR") ? "image/png" : "image/jpeg";
  const json = await respond({
    model: config.model,
    input: [{ role: "user", content: [
      { type: "input_text", text: replyPrompt(input) },
      { type: "input_image", image_url: `data:${mime};base64,${input.image}` },
    ] }],
    reasoning: { effort: "low" },
  }, meter);
  return outputText(json).trim().replace(/^"(.*)"$/s, "$1");
}
