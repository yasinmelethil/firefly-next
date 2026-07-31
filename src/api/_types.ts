/**
 * One PHP `case` block, ported. The case block is the transcription unit -- it
 * owns the whole response, including the exact MESSAGE strings -- so a handler
 * returns a Response rather than data for someone else to shape.
 */
export type Handler = (fd: FormData) => Promise<Response>;

/**
 * What each api module exports: its cases, keyed by the value of the `api` POST
 * field. Kept as an array of pairs rather than an object so _registry.ts can
 * spread several modules into one Map and a duplicate name is easy to detect.
 */
export type Cases = ReadonlyArray<readonly [string, Handler]>;
