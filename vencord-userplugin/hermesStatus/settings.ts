/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { definePluginSettings } from "@api/Settings";
import { OptionType } from "@utils/types";

import { DEFAULT_POLL_INTERVAL_MS } from "./polling";
import { BridgeTokenControl } from "./secret";

export const settings = definePluginSettings({
    bridgeUrl: {
        type: OptionType.STRING,
        description: "Hermes bridge base URL",
        default: "http://127.0.0.1:8765",
        placeholder: "http://127.0.0.1:8765"
    },
    bridgeToken: {
        type: OptionType.COMPONENT,
        component: BridgeTokenControl
    },
    enabledChannelIds: {
        type: OptionType.STRING,
        description: "Selected thread IDs, or parent channel IDs whose Hermes-created threads inherit the status bar",
        default: "",
        multiline: true
    },
    showInParentChannels: {
        type: OptionType.BOOLEAN,
        description: "Also show the status bar in selected parent channels (normally Hermes only chats in their auto-created threads)",
        default: false
    },
    pollingIntervalMs: {
        type: OptionType.NUMBER,
        description: "Polling interval in milliseconds",
        default: DEFAULT_POLL_INTERVAL_MS,
        isValid: value => {
            const interval = Number(value);
            if (!Number.isFinite(interval)) return "Polling interval must be a finite number.";
            if (interval < 500) return "Polling interval must be at least 500ms.";
            if (interval > 60000) return "Polling interval must be at most 60000ms.";
            return true;
        }
    }
});
