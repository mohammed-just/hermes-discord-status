/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import "./styles.css";

import { findGroupChildrenByChildId, NavContextMenuPatchCallback } from "@api/ContextMenu";
import ErrorBoundary from "@components/ErrorBoundary";
import definePlugin from "@utils/types";
import { Menu } from "@webpack/common";

import { getEnabledChannelIds, setChannelEnabled } from "./api";
import { HermesStatusBar } from "./components/HermesStatusBar";
import { settings } from "./settings";

const authors = [{ name: "Mohammed", id: 179181221824299008n }];

const patchChannelContextMenu: NavContextMenuPatchCallback = (children, props) => {
    const channelId = props?.channel?.id;
    if (!channelId) return;

    const enabledIds = getEnabledChannelIds(settings.store.enabledChannelIds);
    const checked = enabledIds.has(channelId);
    const item = (
        <Menu.MenuCheckboxItem
            id="vc-hermes-status-channel"
            label="Show Hermes status here"
            checked={checked}
            action={() => {
                settings.store.enabledChannelIds = setChannelEnabled(settings.store.enabledChannelIds, channelId, !checked);
            }}
        />
    );

    const group = findGroupChildrenByChildId(["mark-channel-read", "mute-channel", "unmute-channel"], children) ?? children;
    group.push(item);
};

export default definePlugin({
    name: "HermesStatus",
    description: "Shows a compact live Hermes bridge status bar above the Discord composer for explicitly enabled channels.",
    authors,
    tags: ["Chat", "Utility"],
    settings,

    contextMenus: {
        "channel-context": patchChannelContextMenu,
        "thread-context": patchChannelContextMenu,
        "gdm-context": patchChannelContextMenu
    },

    patches: [
        {
            find: ".CREATE_FORUM_POST||",
            replacement: [
                {
                    // Discord's current composer renders this effect immediately after
                    // the editor. Access the plugin defensively: this composer can
                    // render before Vencord's PluginManager initializes.
                    match: /\(0,\i\.jsx\)\(\i,\{textValue:\i,editorHeight:\i,channelId:(\i)\.id\}\),/,
                    replace: "$&globalThis.Vencord?.Plugins?.plugins?.HermesStatus?.renderHermesStatusBar($1.id)??null,"
                }
            ],
        }
    ],

    renderHermesStatusBar: (channelId: string) => (
        <ErrorBoundary noop>
            <HermesStatusBar channelId={channelId} />
        </ErrorBoundary>
    )
});

export { settings };
