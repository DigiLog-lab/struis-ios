import Fastify from "fastify";
import { request } from "undici";
const app = Fastify();
app.get("/health", async (): Promise<{ ok: boolean }> => ({ ok: true }));
app.post("/v1/messages", async (req, reply): Promise<void> => {
  const upstream = await request("https://api.anthropic.com/v1/messages", { method: "POST", body: JSON.stringify(req.body) });
  reply.code(upstream.statusCode).send(upstream.body);
});
app.listen({ port: 8080, host: "0.0.0.0" });
