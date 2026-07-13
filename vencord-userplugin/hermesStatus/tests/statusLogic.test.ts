/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { isStatusStale, validateHermesStatus } from "../api";
import { buildStatusFields, statusFieldClassName, statusFieldGroupClassName } from "../format";
import type { HermesStatus } from "../types";

function assertEqual<T>(actual: T, expected: T): void {
    if (actual !== expected) {
        throw new Error(`Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }
}

const status: HermesStatus = {
    schema_version: 1,
    session_id: "s1",
    model: "m",
    context_used: 1000,
    context_max: 2000,
    context_percent: 50,
    total_processed_tokens: 748126,
    session_started_at: 0,
    turn_started_at: 120,
    busy: true,
    active_tool: null,
    tool_calls: 0,
    active_tool_calls: 0,
    compression_count: 2,
    active_subagents: 3,
    yolo: false,
    updated_at: 60,
    error: null
};

assertEqual(isStatusStale(status, 180_000, 2000, 180_000), false);
assertEqual(isStatusStale(status, 180_000, 2000, null), true);

const legacyPayload = {
    ...status,
    active_subagents: undefined,
    active_background_subagents: 4,
    session_started_at: 1_700_000_000,
    turn_started_at: null,
    updated_at: 1_700_000_001
};
const parsed = validateHermesStatus(legacyPayload);
assertEqual(parsed?.active_subagents, 4);

const parsedWithTotal = validateHermesStatus({
    ...status,
    session_started_at: 1_700_000_000,
    turn_started_at: null,
    updated_at: 1_700_000_001,
    total_processed_tokens: 748126
});
assertEqual(parsedWithTotal?.total_processed_tokens, 748126);

const payloadWithoutTotal: Partial<HermesStatus> = {
    ...status,
    session_started_at: 1_700_000_000,
    turn_started_at: null,
    updated_at: 1_700_000_001
};
delete payloadWithoutTotal.total_processed_tokens;
const parsedWithoutTotal = validateHermesStatus(payloadWithoutTotal);
assertEqual(parsedWithoutTotal?.total_processed_tokens, 0);

for (const invalidTotal of [-1, 1.5, "748126", null, Number.MAX_SAFE_INTEGER + 1]) {
    assertEqual(validateHermesStatus({
        ...status,
        session_started_at: 1_700_000_000,
        turn_started_at: null,
        updated_at: 1_700_000_001,
        total_processed_tokens: invalidTotal
    }), null);
}

const idleFields = buildStatusFields({
    channelId: "c1",
    status: {
        ...status,
        busy: false,
        active_tool: null,
        tool_calls: 0,
        active_tool_calls: 0,
        compression_count: 0,
        active_subagents: 0,
        yolo: false
    },
    connectionState: "connected",
    error: null,
    receivedAt: 180_000
}, 180_000);
assertEqual(idleFields.some(field => field.id === "compression"), false);
assertEqual(idleFields.some(field => field.id === "active-subagents"), false);
assertEqual(idleFields.some(field => field.id === "current-turn"), false);
assertEqual(idleFields.some(field => field.id === "yolo"), false);
assertEqual(idleFields.some(field => field.id === "active-tool"), false);
assertEqual(idleFields.some(field => field.id === "active-tool-count"), false);
assertEqual(idleFields.some(field => field.id === "tool-count"), false);
assertEqual(idleFields.map(field => field.id).join(","), "model,context,total-processed,gauge,session-elapsed,freshness,connection");

const activeFields = buildStatusFields({
    channelId: "c1",
    status: {
        ...status,
        active_tool: "shell",
        tool_calls: 9,
        active_tool_calls: 2,
        compression_count: 1,
        active_subagents: 1,
        yolo: true
    },
    connectionState: "connected",
    error: null,
    receivedAt: 180_000
}, 180_000);
assertEqual(activeFields.some(field => field.id === "compression" && field.tooltip === "Compression count: 1"), true);
assertEqual(activeFields.some(field => field.id === "active-subagents" && field.tooltip === "Active subagents: 1"), true);
assertEqual(activeFields.some(field => field.id === "current-turn" && field.tooltip === "Current turn elapsed: 1m"), true);
assertEqual(activeFields.some(field => field.id === "yolo" && field.tooltip === "YOLO mode: dangerous command approvals are bypassed"), true);
assertEqual(activeFields.find(field => field.id === "compression")?.value, "🗜️ 1");
assertEqual(activeFields.find(field => field.id === "active-subagents")?.value, "⛓️ 1");
assertEqual(activeFields.find(field => field.id === "current-turn")?.value, "⏲ 1m");
assertEqual(activeFields.find(field => field.id === "yolo")?.value, "⚠ YOLO");
assertEqual(statusFieldGroupClassName(activeFields.find(field => field.id === "compression")!), "fieldGroup fieldGroup-compression hide-compact");
assertEqual(statusFieldClassName(activeFields.find(field => field.id === "compression")!), "field");
assertEqual(statusFieldGroupClassName(activeFields.find(field => field.id === "current-turn")!), "fieldGroup fieldGroup-current-turn hide-narrow");
assertEqual(statusFieldClassName(activeFields.find(field => field.id === "current-turn")!), "field");
assertEqual(statusFieldGroupClassName(activeFields.find(field => field.id === "active-tool")!), "fieldGroup fieldGroup-active-tool tool");
assertEqual(statusFieldClassName(activeFields.find(field => field.id === "active-tool")!), "field");
assertEqual(activeFields.some(field => field.id === "active-tool" && field.tooltip === "Active tool: shell"), true);
assertEqual(activeFields.some(field => field.id === "active-tool-count" && field.tooltip === "Active tool calls: 2"), true);
assertEqual(activeFields.some(field => field.id === "context" && field.tooltip === "Context window: 1K used of 2K (50%)"), true);
assertEqual(activeFields.find(field => field.id === "total-processed")?.value, "Total 748K");
assertEqual(activeFields.find(field => field.id === "total-processed")?.tooltip, "Total processed: 748,126 tokens");
assertEqual(activeFields.find(field => field.id === "total-processed")?.ariaLabel, "Total processed: 748,126 tokens");
assertEqual(activeFields.map(field => field.id).slice(0, 4).join(","), "model,context,total-processed,gauge");
assertEqual(activeFields.some(field => field.id === "gauge" && field.tooltip === "Context gauge: 50% used"), true);
assertEqual(activeFields.some(field => field.id === "session-elapsed" && field.tooltip === "Session elapsed: 3m"), true);
assertEqual(activeFields.some(field => field.id === "freshness" && field.tooltip === "State last changed: 2m ago"), true);
assertEqual(activeFields.some(field => field.id === "connection" && field.tooltip === "Hermes bridge connected"), true);
