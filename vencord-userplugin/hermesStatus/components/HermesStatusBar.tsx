/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { TooltipContainer } from "@components/TooltipContainer";
import { classNameFactory } from "@utils/css";
import { ChannelType } from "@vencord/discord-types/enums";
import { ChannelStore, SelectedChannelStore, useEffect, useState, useStateFromStores } from "@webpack/common";

import { getEnabledChannelIds, normalizePollInterval } from "../api";
import { buildStatusFields, stateLabel, type StatusField,statusFieldClassName, statusFieldGroupClassName } from "../format";
import { useHermesStatus } from "../hooks/useHermesStatus";
import { useBridgeToken } from "../secret";
import { settings } from "../settings";

const cl = classNameFactory("vc-hermesStatus-");

function Field({ field }: { field: StatusField; }) {
    return (
        <TooltipContainer text={field.tooltip}>
            <span className={statusFieldClassName(field, cl)} aria-label={field.ariaLabel}>
                {field.value}
            </span>
        </TooltipContainer>
    );
}

function FieldGroup({ field, separator }: { field: StatusField; separator: boolean; }) {
    return (
        <span className={statusFieldGroupClassName(field, cl)}>
            {separator && <span className={cl("separator")} aria-hidden="true">|</span>}
            <Field field={field} />
        </span>
    );
}

export function HermesStatusBar({ channelId: patchedChannelId }: { channelId?: string; }) {
    const selectedChannelId = useStateFromStores([SelectedChannelStore], () => SelectedChannelStore.getChannelId());
    const currentSettings = settings.use(["bridgeUrl", "enabledChannelIds", "showInParentChannels", "pollingIntervalMs"]);
    const bridgeToken = useBridgeToken();
    // A mounted composer can outlive Discord's selected-channel store during
    // navigation. Bind status to the composer that was actually patched so a
    // previous channel's token usage cannot leak into another page.
    const channelId = patchedChannelId ?? selectedChannelId ?? null;
    const channel = channelId ? ChannelStore.getChannel(channelId) : null;
    const isThread = channel?.type === ChannelType.ANNOUNCEMENT_THREAD
        || channel?.type === ChannelType.PUBLIC_THREAD
        || channel?.type === ChannelType.PRIVATE_THREAD;
    const enabledIds = getEnabledChannelIds(currentSettings.enabledChannelIds);
    const directlyEnabled = channelId != null && enabledIds.has(channelId);
    const inheritedFromParent = isThread && channel?.parent_id != null && enabledIds.has(channel.parent_id);
    const enabled = isThread
        ? directlyEnabled || inheritedFromParent
        : directlyEnabled && currentSettings.showInParentChannels;
    const [now, setNow] = useState(Date.now());

    const snapshot = useHermesStatus(channelId, enabled, {
        bridgeUrl: currentSettings.bridgeUrl,
        bearerToken: bridgeToken.token,
        bearerTokenError: bridgeToken.error,
        pollingIntervalMs: normalizePollInterval(currentSettings.pollingIntervalMs)
    });

    useEffect(() => {
        if (!enabled) return;
        const interval = setInterval(() => setNow(Date.now()), 1000);
        return () => clearInterval(interval);
    }, [enabled]);

    if (!enabled) return null;

    const visibleSnapshot = snapshot.channelId === channelId ? snapshot : { ...snapshot, status: null, connectionState: "connecting" as const, error: null };
    const { connectionState } = visibleSnapshot;
    const fields = buildStatusFields(visibleSnapshot, now);
    const connectionLabel = stateLabel(connectionState);

    return (
        <div
            className={cl("bar", `state-${connectionState}`)}
            role="status"
            aria-live="polite"
            aria-label={`Hermes status ${connectionLabel}`}
        >
            {fields.map((statusField, index) => <FieldGroup key={statusField.id} field={statusField} separator={index > 0} />)}
        </div>
    );
}
