#!/usr/bin/env node
/** Attach an idempotent lifecycle reaction to a durably captured Discord request. */
import { existsSync, linkSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const reactions = {
	accepted: "✅",
	claimed: "🛠️",
	success: "🟢",
	blocked: "⚠️",
};

function readJson(path) {
	try {
		return JSON.parse(readFileSync(path, "utf8"));
	} catch {
		return null;
	}
}

function publishOnce(path, record) {
	const temporary = `${path}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
	writeFileSync(temporary, JSON.stringify(record), { mode: 0o600, flag: "wx" });
	try {
		linkSync(temporary, path);
		return true;
	} catch (error) {
		if (error.code === "EEXIST") return false;
		throw error;
	} finally {
		try { unlinkSync(temporary); } catch {}
	}
}

function sourceForRequest(stateDir, requestId) {
	if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(requestId)) return null;
	const contextPath = join(stateDir, "x-context", `${requestId}.json`);
	const context = readJson(contextPath);
	if (
		context?.request_id !== requestId ||
		context.platform !== "discord" ||
		context.source !== "discord-selfhosted" ||
		!/^\d+$/.test(context.channel_id || "") ||
		!/^\d+$/.test(context.message_id || "")
	) return null;
	const inbox = readJson(join(stateDir, "x-inbox", `${requestId}.json`));
	if (inbox && (
		inbox.request_id !== requestId ||
		!(["discord-selfhosted", "discord-selfhosted-decision"].includes(inbox.source)) ||
		inbox.channel_id !== context.channel_id ||
		inbox.message_id !== context.message_id
	)) return null;
	return { context };
}

export async function reactToCapturedRequest(stateDir, requestId, phase, token = process.env.FM_DISCORD_BOT_TOKEN || process.env.FM_DISCORD_TOKEN) {
	const emoji = reactions[phase];
	if (!emoji) return false;
	const source = sourceForRequest(stateDir, requestId);
	if (!source) return false;
	const lifecycleDir = join(stateDir, "x-context");
	const prefix = join(lifecycleDir, `discord-lifecycle-${requestId}`);
	const marker = `${prefix}-${phase}.json`;
	const applied = `${marker}.applied`;
	if (phase === "claimed" && !existsSync(`${prefix}-accepted.json`)) return false;
	if (phase === "success" || phase === "blocked") {
		if (!existsSync(`${prefix}-claimed.json`)) {
			if (existsSync(`${prefix}-accepted.json`)) {
				await reactToCapturedRequest(stateDir, requestId, "claimed", token).catch(() => false);
			}
			if (!existsSync(`${prefix}-claimed.json`)) return false;
		}
		if (phase === "blocked" && existsSync(`${prefix}-success.json`)) return false;
	}
	const isDryRun = ["1", "true", "yes"].includes((process.env.FMX_DRY_RUN || "").toLowerCase()) || Boolean(process.env.FMX_DRY);
	if (isDryRun) return false;
	publishOnce(marker, {
		schema: "fm-discord-reaction-lifecycle.v1",
		request_id: requestId,
		phase,
		channel_id: source.context.channel_id,
		message_id: source.context.message_id,
		recorded_at: Math.floor(Date.now() / 1000),
	});
	if (existsSync(applied)) return true;
	if (!token) return false;
	const encodedEmoji = encodeURIComponent(emoji);
	try {
		const response = await fetch(
			`https://discord.com/api/v10/channels/${source.context.channel_id}/messages/${source.context.message_id}/reactions/${encodedEmoji}/@me`,
			{
				method: "PUT",
				headers: { Authorization: `Bot ${token}`, "User-Agent": "FirstmateDiscordSelfHosted/1.0" },
				signal: AbortSignal.timeout(10000),
			},
		);
		if (!response.ok) return false;
		publishOnce(applied, { phase, applied_at: Math.floor(Date.now() / 1000) });
		return true;
	} catch {
		return false;
	}
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
	const [requestId, phase] = process.argv.slice(2);
	const home = process.env.FM_HOME || process.env.FM_ROOT || ".";
	const stateDir = process.env.FM_STATE_OVERRIDE || join(home, "state");
	await reactToCapturedRequest(stateDir, requestId || "", phase || "");
}
