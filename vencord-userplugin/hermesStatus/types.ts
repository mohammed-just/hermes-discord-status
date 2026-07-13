/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

export interface HermesStatus {
    schema_version: 1;
    session_id: string;
    model: string;
    context_used: number | null;
    context_max: number | null;
    context_percent: number | null;
    total_processed_tokens: number;
    session_started_at: number;
    turn_started_at: number | null;
    busy: boolean;
    active_tool: string | null;
    tool_calls: number;
    active_tool_calls: number;
    compression_count: number;
    active_subagents: number;
    yolo: boolean;
    updated_at: number;
    error: string | null;
}

export type ConnectionState = "idle" | "connecting" | "connected" | "stale" | "disconnected" | "error";

export interface HermesSnapshot {
    channelId: string | null;
    status: HermesStatus | null;
    connectionState: ConnectionState;
    error: string | null;
    receivedAt: number | null;
}

export interface PollConfig {
    bridgeUrl: string;
    bearerToken: string;
    bearerTokenError: string | null;
    pollingIntervalMs: number;
}
