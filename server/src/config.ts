/** Everything the server reads from its environment (.env locally, the host's settings in production). */
export const config = {
  openAIKey: process.env.OPENAI_API_KEY ?? "",
  model: process.env.OPENAI_MODEL || "gpt-6-astra",
  exaKey: process.env.EXA_API_KEY ?? "",
  elevenLabsKey: process.env.ELEVENLABS_API_KEY ?? "",
  appToken: process.env.APP_TOKEN ?? "",
  searchLimit: Number(process.env.SEARCH_LIMIT_PER_DAY ?? 40),
  transcribeLimit: Number(process.env.TRANSCRIBE_LIMIT_PER_DAY ?? 120),
  port: Number(process.env.PORT ?? 8787),
  // Upstreams, overridable so tests can point at local stand-ins.
  openAIBase: process.env.OPENAI_BASE_URL || "https://api.openai.com/v1",
  exaBase: process.env.EXA_BASE_URL || "https://api.exa.ai",
  elevenLabsBase: process.env.ELEVENLABS_BASE_URL || "https://api.elevenlabs.io/v1",
  lumaBase: process.env.LUMA_BASE_URL || "https://api.luma.com",
};
