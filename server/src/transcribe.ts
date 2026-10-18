import { config } from "./config.js";

/** Forwards a spoken answer to ElevenLabs Scribe and returns the text. */
export async function transcribe(audio: ArrayBuffer, contentType: string, keyterms: string[]): Promise<string> {
  const form = new FormData();
  form.append("model_id", "scribe_v2");
  form.append("tag_audio_events", "false");
  for (const term of keyterms.slice(0, 10)) form.append("keyterms", term);
  form.append("file", new Blob([audio], { type: contentType || "audio/mp4" }), "answer.m4a");

  const res = await fetch(`${config.elevenLabsBase}/speech-to-text`, {
    method: "POST",
    headers: { "xi-api-key": config.elevenLabsKey },
    body: form,
    signal: AbortSignal.timeout(60_000),
  });
  if (!res.ok) throw new Error(`Transcription failed upstream (${res.status}).`);
  const json = (await res.json()) as { text?: string };
  return (json.text ?? "").trim();
}
