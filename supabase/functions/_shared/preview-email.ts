/** Preview only: no business notification is delivered, even if a key was copied by mistake. */
export async function previewEmail(_url: string | URL | Request, _options?: RequestInit): Promise<Response> {
  return new Response(JSON.stringify({message:"E-postutsending er deaktivert i testversjonen."}), {
    status: 409, headers: {"Content-Type":"application/json"},
  });
}
