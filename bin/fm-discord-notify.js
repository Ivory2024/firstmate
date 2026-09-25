#!/usr/bin/env node
/** Post and bind one proactive decision message using the self-hosted Discord bot. */
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [trigger, taskId, key, summary, channelId, statusTaskId, ...options] = process.argv.slice(2);
const token = process.env.FM_DISCORD_BOT_TOKEN;
const home = process.env.FM_HOME || process.env.FM_ROOT || ".";
const stateDir = process.env.FM_STATE_OVERRIDE || join(home, "state");
const contextDir = join(stateDir, "x-context");

async function main() {
	if (!token || !trigger || !taskId || !key || !summary || !channelId || !statusTaskId || options.length === 0) {
		console.error("fm-discord-notify: required configuration or notification data is missing");
		process.exitCode = 2;
		return;
	}
	if (!existsSync(contextDir)) mkdirSync(contextDir, { recursive: true, mode: 0o700 });
	const eventId = `${trigger}\0${taskId}\0${key}`;
	const digest = createHash("sha256").update(eventId).digest("hex");
	const recordPath = join(contextDir, `discord-notify-${digest}.json`);
	if (existsSync(recordPath)) {
		try {
			const prior = JSON.parse(readFileSync(recordPath, "utf8"));
			if (prior.state !== "failed") {
				console.log(key);
				return;
			}
			unlinkSync(recordPath);
		} catch {
			console.error("fm-discord-notify: existing notification record is unreadable");
			process.exitCode = 1;
			return;
		}
	}

	const initialRecord = {
		schema: "fm-discord-decision-notification.v1",
		kind: "decision-notification",
		state: "sending",
		event_id: digest,
		trigger,
		task_id: taskId,
		key,
		status_task_id: statusTaskId,
		summary,
		options,
		channel_id: channelId,
		recorded_at: Math.floor(Date.now() / 1000),
	};
	try {
		writeFileSync(recordPath, JSON.stringify(initialRecord), { flag: "wx", mode: 0o600 });
	} catch (error) {
		if (error instanceof Error && "code" in error && error.code === "EEXIST") {
			console.log(key);
			return;
		}
		throw error;
	}

	const payload = {
		content: `Task: ${taskId}\n${summary}\nOptions: ${options.join("; ")}\nReply directly to this message with your answer.`,
		allowed_mentions: { parse: [] },
	};
	try {
		const response = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
			method: "POST",
			headers: {
				Authorization: `Bot ${token}`,
				"Content-Type": "application/json",
				"User-Agent": "FirstmateDiscordSelfHosted/1.0",
			},
			body: JSON.stringify(payload),
			signal: AbortSignal.timeout(10000),
		});
		if (!response.ok) throw new Error(`Discord API returned HTTP ${response.status}`);
		const message = await response.json();
		if (typeof message.id !== "string" || message.channel_id !== channelId) {
			throw new Error("Discord API returned an invalid notification receipt");
		}
		const completedRecord = { ...initialRecord, state: "sent", message_id: message.id };
		const temporaryPath = `${recordPath}.${process.pid}.tmp`;
		writeFileSync(temporaryPath, JSON.stringify(completedRecord), { mode: 0o600 });
		renameSync(temporaryPath, recordPath);
		console.log(key);
	} catch (error) {
		try {
			const current = JSON.parse(readFileSync(recordPath, "utf8"));
			if (current.state === "sending") writeFileSync(recordPath, JSON.stringify({ ...current, state: "failed" }), { mode: 0o600 });
		} catch {}
		console.error(`fm-discord-notify: ${error instanceof Error ? error.message : "Discord send failed"}`);
		process.exitCode = 1;
	}
}

main().catch((error) => {
	console.error(`fm-discord-notify: ${error instanceof Error ? error.message : "Discord send failed"}`);
	process.exitCode = 1;
});
