/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 Vendicated and contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import * as DataStore from "@api/DataStore";
import { Button } from "@components/Button";
import { RenderModalProps } from "@vencord/discord-types";
import { Modal, openModal, TextInput, useEffect, useState } from "@webpack/common";

const DATA_STORE_KEY = "HermesStatus_bridgeToken";
let cachedToken: string | undefined;
let cachedTokenError: string | null = null;
const listeners = new Set<(state: BridgeTokenState) => void>();
const TOKEN_STORE_ERROR = "Could not access local Vencord IndexedDB. Check Discord/Vencord storage permissions and try again.";

export interface BridgeTokenState {
    token: string;
    error: string | null;
}

export async function getBridgeToken(): Promise<string> {
    if (cachedToken !== undefined) return cachedToken;
    let value: unknown;
    try {
        value = await DataStore.get<unknown>(DATA_STORE_KEY);
    } catch {
        cachedTokenError = TOKEN_STORE_ERROR;
        throw new Error(TOKEN_STORE_ERROR);
    }
    cachedToken = typeof value === "string" ? value : "";
    cachedTokenError = null;
    return cachedToken;
}

async function getBridgeTokenForPolling(): Promise<BridgeTokenState> {
    try {
        return { token: await getBridgeToken(), error: null };
    } catch (err) {
        return {
            token: "",
            error: err instanceof Error ? err.message : TOKEN_STORE_ERROR
        };
    }
}

async function setBridgeToken(token: string): Promise<void> {
    const nextToken = token.trim();
    try {
        await DataStore.set(DATA_STORE_KEY, nextToken);
    } catch {
        throw new Error(TOKEN_STORE_ERROR);
    }
    cachedToken = nextToken;
    cachedTokenError = null;
    listeners.forEach(listener => listener({ token: nextToken, error: null }));
}

export function useBridgeToken(): BridgeTokenState {
    const [state, setState] = useState<BridgeTokenState>({
        token: cachedToken ?? "",
        error: cachedTokenError
    });

    useEffect(() => {
        void getBridgeTokenForPolling().then(setState);
        listeners.add(setState);
        return () => {
            listeners.delete(setState);
        };
    }, []);

    return state;
}

function BridgeTokenModal({ modalProps }: { modalProps: RenderModalProps; }) {
    const [token, setToken] = useState("");
    const [error, setError] = useState<string | null>(null);

    useEffect(() => {
        void getBridgeToken().then(setToken).catch(() => setError(TOKEN_STORE_ERROR));
    }, []);

    return (
        <Modal
            {...modalProps}
            title="Hermes bridge token"
            subtitle="Stored only in local Vencord IndexedDB; it is not a synced plugin setting."
            actions={[
                { text: "Cancel", variant: "secondary", onClick: modalProps.onClose },
                {
                    text: "Save",
                    variant: "primary",
                    disabled: !token.trim(),
                    onClick: () => {
                        setError(null);
                        void setBridgeToken(token).then(modalProps.onClose).catch(err => {
                            setError(err instanceof Error ? err.message : TOKEN_STORE_ERROR);
                        });
                    }
                }
            ]}
        >
            <TextInput
                value={token}
                type="password"
                autoComplete="off"
                placeholder="Paste the Hermes bridge token"
                onChange={setToken}
            />
            {error && <div className="vc-hermesStatus-tokenError">{error}</div>}
        </Modal>
    );
}

export function BridgeTokenControl() {
    return (
        <Button onClick={() => openModal(modalProps => <BridgeTokenModal modalProps={modalProps} />)}>
            Set local bridge token
        </Button>
    );
}
