#!/usr/bin/env node
/**
 * Self-hosted Discord connector reply helper.
 * Posts reply messages directly to Discord API using native Node 22 fetch.
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { reactToCapturedRequest } from "./fm-discord-reaction.js";

const token = process.env.FM_DISCORD_BOT_TOKEN || process.env.FM_DISCORD_TOKEN;
const fmHome = process.env.FM_HOME || process.env.FM_ROOT || ".";
const stateDir = process.env.FM_STATE_OVERRIDE || join(fmHome, "state");
const contextDir = join(stateDir, "x-context");
const outboxDir = join(stateDir, "x-outbox");

const args = process.argv.slice(2);
if (args.length < 2) {
	console.error("usage: fm-discord-reply.js <request_id> <payload_json_file> [endpoint] [image_path]");
	process.exit(2);
}

const reqId = args[0];
const payloadFile = args[1];
const endpoint = args[2] || "answer";
const imagePath = args[3] || "";

const dryRun = ["1", "true", "yes"].includes((process.env.FMX_DRY_RUN || "").toLowerCase());

async function main() {
	let reqPayload = {};
	try {
		reqPayload = JSON.parse(readFileSync(payloadFile, "utf8"));
	} catch (e) {
		console.error(`fm-discord-reply: cannot read payload file: ${payloadFile}`);
		process.exit(1);
	}

	let channelId = reqPayload.channel_id;
	let messageId = reqPayload.message_id;

	if (!channelId || !messageId) {
		const contextFile = join(contextDir, `${reqId}.json`);
		if (existsSync(contextFile)) {
			try {
				const ctx = JSON.parse(readFileSync(contextFile, "utf8"));
				channelId = channelId || ctx.channel_id;
				messageId = messageId || ctx.message_id;
			} catch (_) {}
		}
	}

	if (dryRun && !channelId) {
		channelId = "dry-run-channel";
	}

	if (!channelId) {
		console.error(`fm-discord-reply: channel_id missing for ${reqId}`);
		process.exit(1);
	}

	const text = reqPayload.text || (Array.isArray(reqPayload.texts) ? reqPayload.texts.join("\n\n") : "");
	const chunks = Array.isArray(reqPayload.texts) && reqPayload.texts.length > 0 ? reqPayload.texts : [text];

	// A captain decision ask must carry a durable correlation identity, which only
	// the keyed decision notification path registers (bin/fm-discord-notify.sh
	// <trigger> ...). This reply path posts ordinary answers to an inbound
	// request, so a decision ask sent here would arrive back as generic work with
	// nothing to correlate it against. The marker itself is defined once in
	// bin/fm-discord-lib.sh and exported by the wrapper.
	const decisionMarker = process.env.FM_DISCORD_DECISION_MARKER;
	if (!decisionMarker) {
		console.error("fm-discord-reply: FM_DISCORD_DECISION_MARKER is unset; refusing to send an unregistered reply");
		process.exit(2);
	}
	if (chunks.some((chunk) => typeof chunk === "string" && chunk.includes(decisionMarker))) {
		console.error("fm-discord-reply: a captain decision ask cannot be sent as an ordinary reply; use bin/fm-discord-notify.sh <trigger> <task-id> <key> <summary> <option|option...> <recommendation>");
		process.exit(2);
	}

	if (dryRun) {
		if (!existsSync(outboxDir)) mkdirSync(outboxDir, { recursive: true, mode: 0o700 });
		const outboxRecord = {
			request_id: reqId,
			platform: "discord",
			source: "discord-selfhosted",
			text: text,
			texts: chunks,
			endpoint: endpoint,
		};
		if (imagePath) {
			outboxRecord.image = { source_path: imagePath };
		}
		writeFileSync(join(outboxDir, `${reqId}.json`), JSON.stringify(outboxRecord, null, 2), { mode: 0o600 });
		console.error(`fm-discord-reply: DRY RUN - would POST reply to Discord channel ${channelId} (recorded: state/x-outbox/${reqId}.json)`);
		console.log(reqId);
		process.exit(0);
	}

	if (!token) {
		console.error("fm-discord-reply: self-hosted Discord mode not configured (no FM_DISCORD_BOT_TOKEN)");
		process.exit(1);
	}

	const apiHeaders = {
		Authorization: `Bot ${token}`,
		"User-Agent": "FirstmateDiscordSelfHosted/1.0",
	};

	// Per-request send progress so a retry after a partial failure does not
	// repost chunks that already reached Discord.
	const progressFile = join(outboxDir, `${reqId}.progress.json`);
	let startIndex = 0;
	let lastMsgId = messageId;
	if (existsSync(progressFile)) {
		try {
			const progress = JSON.parse(readFileSync(progressFile, "utf8"));
			if (Number.isInteger(progress.nextIndex)) startIndex = progress.nextIndex;
			if (progress.lastMsgId) lastMsgId = progress.lastMsgId;
		} catch (_err) {}
	}

	for (let i = startIndex; i < chunks.length; i++) {
		const chunkText = chunks[i];
		const isFirst = i === 0;

		const msgPayload = {
			content: chunkText,
			message_reference: lastMsgId
				? {
						message_id: lastMsgId,
						fail_if_not_exists: false,
				  }
				: undefined,
		};

		let res;
		if (isFirst && imagePath && existsSync(imagePath)) {
			const formData = new FormData();
			formData.append("payload_json", JSON.stringify(msgPayload));
			const fileBuffer = readFileSync(imagePath);
			const fileName = imagePath.split("/").pop() || "image.png";
			formData.append("files[0]", new Blob([fileBuffer]), fileName);

			res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
				method: "POST",
				headers: apiHeaders,
				body: formData,
			});
		} else {
			res = await fetch(`https://discord.com/api/v10/channels/${channelId}/messages`, {
				method: "POST",
				headers: { ...apiHeaders, "Content-Type": "application/json" },
				body: JSON.stringify(msgPayload),
			});
		}

		if (!res.ok) {
			const errText = await res.text();
			console.error(`fm-discord-reply: Discord API returned HTTP ${res.status}: ${errText}`);
			process.exit(1);
		}

		const sentMsg = await res.json();
		if (sentMsg && sentMsg.id) {
			lastMsgId = sentMsg.id;
		}

		if (!existsSync(outboxDir)) mkdirSync(outboxDir, { recursive: true, mode: 0o700 });
		writeFileSync(progressFile, JSON.stringify({ nextIndex: i + 1, lastMsgId }), { mode: 0o600 });
	}

	try {
		if (existsSync(progressFile)) unlinkSync(progressFile);
	} catch (_err) {}
	if (endpoint === "answer" || endpoint === "final") {
		await reactToCapturedRequest(stateDir, reqId, "success").catch(() => false);
	}

	console.log(reqId);
}

main();
