// Production server for buildpack-based hosts (Koyeb, Heroku, ...).
// Serves the built demo and a wisp server on a single port, since these
// platforms only route one port to the app.
import { createReadStream } from "node:fs";
import fs from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { server as wisp } from "@mercuryworkshop/wisp-js/server";

const PORT = Number(process.env.PORT || 8000);
const WISP_PATH = "/wisp/";
const ROOT = path.resolve(
	path.dirname(fileURLToPath(import.meta.url)),
	"../packages/demo/dist",
);

const MIME_TYPES = {
	".html": "text/html; charset=utf-8",
	".js": "text/javascript; charset=utf-8",
	".mjs": "text/javascript; charset=utf-8",
	".css": "text/css; charset=utf-8",
	".json": "application/json; charset=utf-8",
	".map": "application/json; charset=utf-8",
	".wasm": "application/wasm",
	".png": "image/png",
	".jpg": "image/jpeg",
	".svg": "image/svg+xml",
	".ico": "image/x-icon",
	".ttf": "font/ttf",
	".woff": "font/woff",
	".woff2": "font/woff2",
	".txt": "text/plain; charset=utf-8",
};

// the demo is meant to be public, so don't let it reach the host's network
wisp.options.allow_private_ips = process.env.WISP_ALLOW_PRIVATE_IPS === "1";
wisp.options.allow_loopback_ips = process.env.WISP_ALLOW_LOOPBACK_IPS === "1";

async function resolveFile(pathname) {
	const file = path.join(ROOT, pathname);
	if (file !== ROOT && !file.startsWith(ROOT + path.sep)) return null;
	try {
		const stat = await fs.stat(file);
		if (stat.isFile()) return { file, stat };
		if (stat.isDirectory())
			return resolveFile(path.join(pathname, "index.html"));
	} catch {}
	return null;
}

const server = http.createServer(async (req, res) => {
	if (req.method !== "GET" && req.method !== "HEAD") {
		res.writeHead(405, { Allow: "GET, HEAD" });
		res.end();
		return;
	}

	let pathname;
	try {
		pathname = decodeURIComponent(
			new URL(req.url, "http://localhost").pathname,
		);
	} catch {
		res.writeHead(400);
		res.end();
		return;
	}

	let found = await resolveFile(pathname);
	// behave like the vite dev server: unknown pages get the app shell
	if (!found && req.headers.accept?.includes("text/html")) {
		found = await resolveFile("/index.html");
	}
	if (!found) {
		res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
		res.end("Not found");
		return;
	}

	const { file, stat } = found;
	res.writeHead(200, {
		"Content-Type":
			MIME_TYPES[path.extname(file).toLowerCase()] ??
			"application/octet-stream",
		"Content-Length": stat.size,
		"Cache-Control": file.endsWith(".html")
			? "no-cache"
			: "public, max-age=3600",
	});
	if (req.method === "HEAD") {
		res.end();
		return;
	}
	createReadStream(file).pipe(res);
});

server.on("upgrade", (req, socket, head) => {
	if (req.url?.startsWith(WISP_PATH)) {
		wisp.routeRequest(req, socket, head);
	} else {
		socket.end();
	}
});

server.listen(PORT, () => {
	console.log(`scramjet listening on port ${PORT}`);
	console.log(`demo: http://localhost:${PORT}/`);
	console.log(`wisp: ws://localhost:${PORT}${WISP_PATH}`);
});
