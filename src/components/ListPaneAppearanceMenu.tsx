/*
 * Notebook Navigator - Plugin for Obsidian
 * Copyright (c) 2025-2026 Johan Sanneblad
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import { Menu, TFolder } from 'obsidian';
import { strings } from '../i18n';
import { getDefaultListMode, resolveListMode, type FolderAppearance } from '../hooks/useListPaneAppearance';
import type { ListDisplayMode, NotebookNavigatorSettings } from '../settings/types';
import { ItemType } from '../types';
import { runAsyncAction } from '../utils/async';
import { ensureRecord, sanitizeRecord } from '../utils/recordUtils';
import type { PropertySelectionNodeId } from '../utils/propertyTree';

interface AppearanceMenuProps {
    event: MouseEvent;
    settings: NotebookNavigatorSettings;
    selectedFolder: TFolder | null;
    selectedTag?: string | null;
    selectedProperty?: PropertySelectionNodeId | null;
    selectionType?: ItemType;
    updateSettings: (updater: (settings: NotebookNavigatorSettings) => void) => Promise<void>;
    descendantAction?: {
        menuTitle: string;
        onApply: () => void;
        disabled?: boolean;
    };
    defaultSettingsAction?: {
        menuTitle: string;
        onOpen: () => void;
        disabled?: boolean;
    };
}

interface AppearanceRecordAccessor {
    key: string;
    getRecord: (settings: NotebookNavigatorSettings) => Record<string, FolderAppearance> | undefined;
    setRecord: (settings: NotebookNavigatorSettings, next: Record<string, FolderAppearance>) => void;
}

export function showListPaneAppearanceMenu({
    event,
    settings,
    selectedFolder,
    selectedTag,
    selectedProperty,
    selectionType,
    updateSettings,
    descendantAction,
    defaultSettingsAction
}: AppearanceMenuProps) {
    const defaultMode: ListDisplayMode = getDefaultListMode(settings);
    const resolveAppearanceAccessor = (): AppearanceRecordAccessor | null => {
        if (selectionType === ItemType.TAG && selectedTag) {
            return {
                key: selectedTag,
                getRecord: targetSettings => targetSettings.tagAppearances,
                setRecord: (targetSettings, next) => {
                    targetSettings.tagAppearances = next;
                }
            };
        }
        if (selectionType === ItemType.FOLDER && selectedFolder) {
            return {
                key: selectedFolder.path,
                getRecord: targetSettings => targetSettings.folderAppearances,
                setRecord: (targetSettings, next) => {
                    targetSettings.folderAppearances = next;
                }
            };
        }
        if (selectionType === ItemType.PROPERTY && selectedProperty) {
            return {
                key: selectedProperty,
                getRecord: targetSettings => targetSettings.propertyAppearances,
                setRecord: (targetSettings, next) => {
                    targetSettings.propertyAppearances = next;
                }
            };
        }
        return null;
    };
    const appearanceAccessor = resolveAppearanceAccessor();

    const updateAppearance = (updates: Partial<FolderAppearance>) => {
        const normalizeAppearance = (appearance: FolderAppearance) => {
            const normalized = { ...appearance };
            (Object.keys(normalized) as (keyof FolderAppearance)[]).forEach(key => {
                if (normalized[key] === undefined) {
                    delete normalized[key];
                }
            });
            if (normalized.mode === defaultMode) {
                delete normalized.mode;
            }
            return normalized;
        };

        if (!appearanceAccessor) {
            return;
        }

        runAsyncAction(() =>
            updateSettings(s => {
                const next = sanitizeRecord(ensureRecord(appearanceAccessor.getRecord(s)));
                const currentAppearance = next[appearanceAccessor.key] || {};
                const normalizedAppearance = normalizeAppearance({ ...currentAppearance, ...updates });
                if (Object.keys(normalizedAppearance).length === 0) {
                    delete next[appearanceAccessor.key];
                } else {
                    next[appearanceAccessor.key] = normalizedAppearance;
                }

                appearanceAccessor.setRecord(s, next);
            })
        );
    };

    const menu = new Menu();

    // Get custom appearance settings for the selected folder/tag
    // Will be undefined if no custom appearance has been set
    const appearance = appearanceAccessor ? appearanceAccessor.getRecord(settings)?.[appearanceAccessor.key] : undefined;
    const effectiveMode = resolveListMode({ appearance, defaultMode });

    const isStandard = effectiveMode === 'standard';
    const isCompact = effectiveMode === 'compact';
    const appearanceMode = appearance?.mode;
    const hasAppearanceOverride =
        ((appearanceMode === 'standard' || appearanceMode === 'compact') && appearanceMode !== defaultMode) ||
        appearance?.titleRows !== undefined ||
        appearance?.previewRows !== undefined;
    const withDefaultSuffix = (label: string, isDefault: boolean): string =>
        isDefault ? `${label} ${strings.folderAppearance.defaultSuffix}` : label;

    menu.addItem(item => {
        item.setTitle(strings.folderAppearance.appearance).setIcon('lucide-palette').setDisabled(true);
    });

    // Standard preset
    menu.addItem(item => {
        const label = withDefaultSuffix(strings.folderAppearance.standardPreset, defaultMode === 'standard');
        item.setTitle(label)
            .setIcon('lucide-list')
            .setChecked(isStandard)
            .onClick(() => {
                updateAppearance({ mode: 'standard' });
            });
    });

    // Compact preset
    menu.addItem(item => {
        const label = withDefaultSuffix(strings.folderAppearance.compactPreset, defaultMode === 'compact');
        item.setTitle(label)
            .setIcon('lucide-align-left')
            .setChecked(isCompact)
            .onClick(() => {
                updateAppearance({ mode: 'compact', previewRows: undefined });
            });
    });

    menu.addSeparator();

    // Title rows header
    menu.addItem(item => {
        item.setTitle(strings.folderAppearance.titleRows).setIcon('lucide-text').setDisabled(true);
    });

    // Title row options
    const effectiveTitleRows = appearance?.titleRows ?? settings.fileNameRows;
    [1, 2, 3].forEach(rows => {
        const isDefaultRows = rows === settings.fileNameRows;
        menu.addItem(item => {
            item.setTitle(`    ${withDefaultSuffix(strings.folderAppearance.titleRowOption(rows), isDefaultRows)}`)
                .setIcon('lucide-text')
                .setChecked(effectiveTitleRows === rows)
                .onClick(() => {
                    updateAppearance({ titleRows: isDefaultRows ? undefined : rows });
                });
        });
    });

    // Auto title rows option
    menu.addItem(item => {
        const isDefaultRows = settings.fileNameRows === 0;
        item.setTitle(`    ${withDefaultSuffix(strings.folderAppearance.autoTitleRowOption, isDefaultRows)}`)
            .setIcon('lucide-text')
            .setChecked(effectiveTitleRows === 0)
            .onClick(() => {
                updateAppearance({ titleRows: isDefaultRows ? undefined : 0 });
            });
    });

    if (settings.showFilePreview && !isCompact) {
        menu.addSeparator();

        // Preview rows header
        menu.addItem(item => {
            item.setTitle(strings.folderAppearance.previewRows).setIcon('lucide-file-text').setDisabled(true);
        });

        // Preview row options
        const effectivePreviewRows = appearance?.previewRows ?? settings.previewRows;
        [1, 2, 3, 4, 5].forEach(rows => {
            const isDefaultRows = rows === settings.previewRows;
            menu.addItem(item => {
                item.setTitle(`    ${withDefaultSuffix(strings.folderAppearance.previewRowOption(rows), isDefaultRows)}`)
                    .setIcon('lucide-file-text')
                    .setChecked(effectivePreviewRows === rows)
                    .onClick(() => {
                        updateAppearance({ previewRows: isDefaultRows ? undefined : rows });
                    });
            });
        });
    }

    if (descendantAction) {
        menu.addSeparator();
        menu.addItem(item => {
            item.setTitle(descendantAction.menuTitle)
                .setIcon('lucide-squares-unite')
                .setDisabled(Boolean(descendantAction.disabled))
                .onClick(() => {
                    descendantAction.onApply();
                });
        });
    }

    if (defaultSettingsAction) {
        menu.addSeparator();
        menu.addItem(item => {
            item.setTitle(strings.paneHeader.resetViewToDefaults)
                .setIcon('lucide-rotate-ccw')
                .setDisabled(!hasAppearanceOverride)
                .onClick(() => {
                    if (!hasAppearanceOverride) {
                        return;
                    }
                    updateAppearance({ mode: undefined, titleRows: undefined, previewRows: undefined });
                });
        });
        menu.addSeparator();
        menu.addItem(item => {
            item.setTitle(defaultSettingsAction.menuTitle)
                .setIcon('lucide-settings')
                .setDisabled(Boolean(defaultSettingsAction.disabled))
                .onClick(() => {
                    defaultSettingsAction.onOpen();
                });
        });
    }

    menu.showAtMouseEvent(event);
}
