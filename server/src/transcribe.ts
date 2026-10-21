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

/**
 * Live dictation: the phone streams its microphone straight to ElevenLabs Scribe v2 Realtime, with a single use
 * token (15 minutes, one session) so the API key never leaves this server. Returns the socket URL to open.
 */
export async function realtimeURL(): Promise<string> {
  const res = await fetch(`${config.elevenLabsBase}/single-use-token/realtime_scribe`, {
    method: "POST",
    headers: { "xi-api-key": config.elevenLabsKey },
    signal: AbortSignal.timeout(10_000),
  });
  if (!res.ok) throw new Error(`Voice token failed upstream (${res.status}).`);
  const { token } = (await res.json()) as { token?: string };
  if (!token) throw new Error("Voice token missing upstream.");
  const socket = new URL(config.elevenLabsRealtimeBase);
  socket.pathname = "/v1/speech-to-text/realtime";
  socket.search = new URLSearchParams({
    model_id: "scribe_v2_realtime",
    audio_format: "pcm_16000",
    // Segments settle on each pause, so long answers keep their earlier words fixed while new ones stream in.
    commit_strategy: "vad",
    token,
  }).toString();
  return socket.toString();
}
