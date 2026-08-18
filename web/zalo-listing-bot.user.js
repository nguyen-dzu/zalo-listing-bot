// ==UserScript==
// @name         Zalo Listing Bot — Web Bridge
// @namespace    zalo-listing-bot
// @version      4.3.20
// @description  Single-tab Zalo Web: harvest source groups then switch to sale group in-place
// @match        *://chat.zalo.me/*
// @match        *://chat.zalo.me/
// @match        *://*.zalo.me/*
// @include      *://chat.zalo.me/*
// @grant        GM_xmlhttpRequest
// @grant        window.onurlchange
// @connect      127.0.0.1
// @connect      zdn.vn
// @connect      zadn.vn
// @connect      zaloapp.com
// @connect      dlfl.vn
// @connect      zalo.me
// @connect      *
// @run-at       document-start
// ==/UserScript==

(function () {
    'use strict';

    const SCRIPT_VERSION = '4.3.20';
    const BRIDGE = {
        host: '127.0.0.1',
        port: 8080,
        pollMs: 400,
        role: 'unknown'
    };

    const SELECTORS = {
        messagePane: [
            '#messageView',
            '[class*="message-list"]',
            '[class*="chatView"]',
            '[class*="chat-content"]',
            'main [class*="scroll"]'
        ],
        messageItemTiers: [
            '[data-id="chat-item"]',
            '[data-id*="msg"]',
            'div[id^="msg-"]',
            '[role="listitem"]',
            '[class*="message-item"]',
            '[class*="msg-item"]',
            '.chat-item',
            '[class*="chat-message"]'
        ],
        messageText: [
            'span[data-translate-inner="TEXT"]',
            '[class*="text-content"]',
            '[class*="message-text"]',
            '[class*="text-message"]'
        ],
        messageImage: 'img[src*="blob:"], img[src*="zdn"], img[src*="zadn"], img[src*="zalo"], img[data-src*="zdn"], img[data-src*="blob"], img[data-src*="zadn"], img[class*="image"], img[class*="photo"]',
        composeBox: [
            'div[contenteditable="true"][role="textbox"]',
            '[class*="chat-input"] [contenteditable="true"]',
            'div[contenteditable="true"]',
            'textarea[class*="input"]'
        ],
        sidebarSearch: [
            'input[placeholder*="Tìm"]',
            'input[placeholder*="tim"]',
            'input[placeholder*="Tìm kiếm"]',
            'input[aria-label*="Tìm"]',
            'input[aria-label*="tim"]',
            'input[type="search"]',
            '[class*="search"] input',
            '[class*="search-input"]',
            '[class*="search"] [contenteditable="true"]',
            '[class*="sidebar"] input[type="text"]',
            '[class*="left-side"] input[type="text"]',
            '[class*="conv-list"] input[type="text"]'
        ],
        conversationTitle: [
            '[class*="header-title"]',
            '[class*="conv-title"]',
            '[class*="thread-title"]',
            '[class*="chat-header"] [class*="title"]',
            '[class*="chat-header"] [class*="name"]',
            '[class*="header"] [class*="title"]',
            '[class*="header"] [class*="name"]',
            'header h1',
            'header h2',
            'header [class*="name"]'
        ],
        sidebarItem: [
            '[class*="conv-item"]',
            '[class*="conversation-item"]',
            '[class*="chat-item"]',
            '[role="listitem"]'
        ],
        searchResultItem: [
            '[class*="search-result"] [class*="item"]',
            '[class*="SearchResult"]',
            '[class*="search-list"] [class*="item"]',
            '[class*="global-search"] [class*="item"]',
            '[class*="result-list"] [class*="item"]',
            '[class*="search"] [class*="conv-item"]',
            '[class*="search"] [class*="conversation"]'
        ],
        unreadBadge: [
            '[class*="badge"]',
            '[class*="unread"]',
            '[class*="count"]'
        ],
        excludeRegions: [
            '[class*="sidebar"]',
            '[class*="search"]',
            'header',
            '[class*="chat-input"]',
            '[class*="compose"]'
        ]
    };

    let lastPushHash = '';
    let observer = null;
    let pollTimer = null;
    let registerTimer = null;
    let observerDebounce = null;
    let pollBusy = false;
    let pollBusySince = 0;
    let lastDomDiagnostics = { matchedSelector: '', messageCount: 0 };
    let lastScanDebug = {
        collected: 0, windowed: 0, divider: 0, imageOnly: 0, rawImgs: 0
    };
    let outputGroupNames = [];
    let eventsPaused = false;

    function qs(selectors, root = document) {
        const list = Array.isArray(selectors) ? selectors : [selectors];
        for (const sel of list) {
            const el = root.querySelector(sel);
            if (el) return el;
        }
        return null;
    }

    function sleep(ms) {
        return new Promise(r => setTimeout(r, ms));
    }

    function normalizeText(text) {
        return (text || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
    }

    function normalizeGroupName(name) {
        return normalizeText(name)
            .toLocaleLowerCase('vi')
            .replace(/[“”„‟]/g, '"')
            .replace(/\u00a0/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
    }

    function groupNamesMatch(actual, expected) {
        const e = normalizeGroupName(expected);
        if (!e) return false;
        // Search-result containers often include preview text on later lines.
        // Match only a complete title line; substring matching can open a
        // similarly named group and leave the previous conversation active.
        return normalizeText(actual)
            .split('\n')
            .some(line => normalizeGroupName(line) === e);
    }

    function setControlledInputValue(input, value) {
        const prototype = input instanceof HTMLTextAreaElement
            ? HTMLTextAreaElement.prototype
            : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
        if (setter) setter.call(input, value);
        else input.value = value;
        input.dispatchEvent(new InputEvent('input', {
            bubbles: true,
            inputType: 'insertText',
            data: value
        }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
    }

    function fnvHash(text) {
        const s = normalizeText(text).replace(/\s+/g, '');
        let h = 2166136261;
        for (let i = 0; i < s.length; i++) {
            h ^= s.charCodeAt(i);
            h = Math.imul(h, 16777619);
        }
        return (h >>> 0).toString(16).padStart(8, '0');
    }

    function http(method, path, body) {
        const url = `http://${BRIDGE.host}:${BRIDGE.port}${path}`;
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method,
                url,
                headers: body ? { 'Content-Type': 'application/json' } : undefined,
                data: body ? JSON.stringify(body) : undefined,
                timeout: path.indexOf('/api/command') === 0 ? 4000 : 8000,
                onload(resp) {
                    try {
                        resolve({
                            status: resp.status,
                            body: resp.responseText ? JSON.parse(resp.responseText) : {}
                        });
                    } catch (e) {
                        resolve({ status: resp.status, body: resp.responseText || '' });
                    }
                },
                onerror(err) {
                    reject(err || new Error('gm_onerror'));
                },
                ontimeout() {
                    reject(new Error('bridge timeout'));
                }
            });
        });
    }

    function detectRole() {
        // Zalo Web single-session: one tab handles harvest + publish in-place.
        sessionStorage.setItem('zaloListingBotRole', 'bot');
        return 'bot';
    }

    function applyRoleTitle() {
        if (!document.title) return;
        const base = document.title.replace(/^\[(ZaloBot|Harvest|Publish)\]\s*/, '');
        const next = '[ZaloBot] ' + (base || 'Zalo');
        if (document.title !== next)
            document.title = next;
    }

    function showStatusBadge() {
        if (document.getElementById('zalo-listing-bot-badge')) return;
        const badge = document.createElement('div');
        badge.id = 'zalo-listing-bot-badge';
        badge.textContent = 'ZaloBot ON';
        badge.style.cssText = [
            'position:fixed', 'top:8px', 'right:8px', 'z-index:2147483647',
            'background:#0068ff', 'color:#fff', 'font:12px/1.4 sans-serif',
            'padding:4px 8px', 'border-radius:4px', 'pointer-events:none'
        ].join(';');
        (document.body || document.documentElement).appendChild(badge);
    }

    function isOutputGroup(name) {
        const actual = normalizeText(name).toLocaleLowerCase('vi');
        if (!actual) return false;
        return outputGroupNames.some(expected => groupNamesMatch(actual, expected));
    }

    function isExcludedElement(el) {
        if (!el) return true;
        for (const sel of SELECTORS.excludeRegions) {
            if (el.closest(sel)) return true;
        }
        if (el.closest(SELECTORS.composeBox[0]) || el.closest('[contenteditable="true"]')) {
            const ce = el.closest('[contenteditable]');
            if (ce && ce.getAttribute('contenteditable') === 'true') return true;
        }
        return false;
    }

    function getMessagePane() {
        return qs(SELECTORS.messagePane) || document.body;
    }

    function scoreMessageElement(el, pane) {
        if (!el || isExcludedElement(el)) return -9999;
        let score = 0;
        if (pane && pane.contains(el)) score += 2;
        const text = extractMessageText(el);
        if (text.length > 12) score += 3;
        let sizedPhotos = 0;
        for (const img of el.querySelectorAll('img')) {
            if (!isAvatarImage(img) && isSizedMessageMedia(img)) sizedPhotos++;
        }
        if (sizedPhotos >= 2) score += 4;
        else if (sizedPhotos === 1) score += 2;
        if (extractMessageImages(el).length) score += 2;
        if (el.querySelector('img, video, [class*="photo"], [class*="album"], [class*="media"]')) score += 1;
        return score;
    }

    function findMessageElements() {
        const pane = getMessagePane();
        const seen = new Set();
        const scored = [];
        let matchedSelector = '';

        for (const sel of SELECTORS.messageItemTiers) {
            const nodes = pane.querySelectorAll(sel);
            if (!nodes.length) continue;
            for (const el of nodes) {
                if (seen.has(el)) continue;
                seen.add(el);
                const score = scoreMessageElement(el, pane);
                if (score < 0) continue;
                if (!matchedSelector) matchedSelector = sel;
                scored.push({ el, score, selector: sel });
            }
        }

        // Zalo image bubbles sometimes expose only a stable CDN src. Walk up
        // to the nearest message-shaped ancestor instead of relying on classes.
        for (const media of pane.querySelectorAll('img, video')) {
            let candidate = media.parentElement;
            let best = null;
            for (let depth = 0; candidate && depth < 8; depth++, candidate = candidate.parentElement) {
                if (candidate === pane || isExcludedElement(candidate)) break;
                const score = scoreMessageElement(candidate, pane);
                if (score >= 2) {
                    best = { el: candidate, score, selector: 'media ancestor' };
                    break;
                }
            }
            if (best && !seen.has(best.el)) {
                seen.add(best.el);
                scored.push(best);
            }
        }

        // Some Zalo builds no longer expose a stable message-item wrapper.
        // Keep the text node itself as a last structured source; standalone
        // image bubbles collected above are associated by DOM order later.
        const hasTextCandidate = scored.some(item =>
            extractMessageText(item.el).length > 0);
        if (!hasTextCandidate) {
            for (const sel of SELECTORS.messageText) {
                for (const el of pane.querySelectorAll(sel)) {
                    if (seen.has(el) || isExcludedElement(el)) continue;
                    const text = extractMessageText(el);
                    if (!text) continue;
                    seen.add(el);
                    scored.push({ el, score: 3, selector: `text fallback: ${sel}` });
                    if (!matchedSelector) matchedSelector = `text fallback: ${sel}`;
                }
            }
        }

        if (!scored.length) {
            matchedSelector = 'div[contenteditable="false"]';
            const fallback = pane.querySelectorAll('div[contenteditable="false"]');
            for (const el of fallback) {
                if (seen.has(el) || isExcludedElement(el)) continue;
                const score = scoreMessageElement(el, pane);
                if (score < 1) continue;
                seen.add(el);
                scored.push({ el, score, selector: matchedSelector });
            }
        }

        const byDomOrder = [...scored].sort((a, b) => {
            const pos = a.el.compareDocumentPosition(b.el);
            if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return -1;
            if (pos & Node.DOCUMENT_POSITION_PRECEDING) return 1;
            return 0;
        });

        lastDomDiagnostics = {
            matchedSelector: matchedSelector || (byDomOrder[0] ? byDomOrder[0].selector : ''),
            messageCount: byDomOrder.length
        };

        return byDomOrder.map(item => item.el);
    }

    function getConversationTitle() {
        const el = qs(SELECTORS.conversationTitle);
        if (el) return normalizeText(el.innerText || el.textContent);
        const header = qs([
            '[class*="chat-header"]',
            '[class*="header-chat"]',
            'header'
        ]);
        if (header) {
            const name = header.querySelector(
                '[class*="title"], [class*="name"], h1, h2, span');
            if (name) return normalizeText(name.innerText || name.textContent);
        }
        return '';
    }

    function extractMessageText(item) {
        const parts = [];
        const seen = new Set();
        for (const sel of SELECTORS.messageText) {
            for (const el of item.querySelectorAll(sel)) {
                const t = normalizeText(el.innerText || el.textContent);
                if (!t || seen.has(t)) continue;
                seen.add(t);
                parts.push(t);
            }
        }
        if (parts.length) {
            parts.sort((a, b) => b.length - a.length);
            const kept = [];
            for (const p of parts) {
                if (!kept.some(k => k.includes(p)))
                    kept.push(p);
            }
            return kept.join('\n');
        }
        const clone = item.cloneNode(true);
        clone.querySelectorAll('img, button, svg, [class*="time"], [class*="avatar"]').forEach(n => n.remove());
        return normalizeText(clone.innerText || clone.textContent);
    }

    function isPlaceholderImageSrc(src) {
        const value = String(src || '').trim().toLowerCase();
        if (!value || value === 'about:blank') return true;
        if (value.startsWith('data:image/gif')) return true;
        if (value.startsWith('data:image/png') && value.length < 180) return true;
        if (value.startsWith('data:image/jpeg') && value.length < 180) return true;
        return false;
    }

    function mediaElementSize(el) {
        if (!el) return { w: 0, h: 0 };
        const rect = el.getBoundingClientRect ? el.getBoundingClientRect() : { width: 0, height: 0 };
        const w = el.naturalWidth || el.videoWidth || el.width || rect.width || 0;
        const h = el.naturalHeight || el.videoHeight || el.height || rect.height || 0;
        return { w, h };
    }

    function isSizedMessageMedia(el) {
        const { w, h } = mediaElementSize(el);
        return w >= 44 && h >= 44;
    }

    function isChatImageUrl(url, contextEl) {
        const value = String(url || '').trim();
        if (isPlaceholderImageSrc(value)) return false;
        const lower = value.toLowerCase();
        if (/avatar|emoji|sticker|icon|logo|badge|thumb-default|favicon/i.test(lower))
            return false;
        if (lower.includes('blob:')
            || lower.includes('zdn.vn')
            || lower.includes('zadn.vn')
            || lower.includes('dlfl.vn')
            || lower.includes('photo.')
            || lower.includes('zalo')
            || lower.includes('chat-photo')
            || lower.includes('chat-img'))
            return true;
        if (contextEl && isSizedMessageMedia(contextEl)
            && (lower.startsWith('https://') || lower.startsWith('http://')))
            return true;
        return false;
    }

    function parseSrcsetValue(srcset) {
        const raw = String(srcset || '').trim();
        if (!raw) return '';
        return raw.split(',')[0].trim().split(/\s+/)[0] || '';
    }

    function resolveImageUrl(img) {
        if (!img) return '';
        const candidates = [
            img.currentSrc,
            img.src,
            img.getAttribute('data-src'),
            img.getAttribute('data-original'),
            img.getAttribute('data-url'),
            img.getAttribute('data-lazy-src'),
            img.getAttribute('data-thumb'),
            parseSrcsetValue(img.srcset || img.getAttribute('srcset'))
        ];
        let parent = img.parentElement;
        for (let depth = 0; parent && depth < 4; depth++, parent = parent.parentElement) {
            candidates.push(
                parent.getAttribute('data-src'),
                parent.getAttribute('data-url'),
                parent.getAttribute('data-original'),
                parent.getAttribute('data-thumb')
            );
        }
        for (const candidate of candidates) {
            if (isChatImageUrl(candidate, img)) return candidate;
        }
        return '';
    }

    function extractVideoUrls(item) {
        const urls = [];
        const seen = new Set();
        for (const video of item.querySelectorAll('video')) {
            if (isAvatarImage(video)) continue;
            const candidates = [
                video.currentSrc,
                video.src,
                video.getAttribute('data-src'),
                video.getAttribute('data-url')
            ];
            for (const candidate of candidates) {
                const value = String(candidate || '').trim();
                if (!value || seen.has(value)) continue;
                if (value.startsWith('blob:') || /^https?:/i.test(value)) {
                    seen.add(value);
                    urls.push(value);
                    break;
                }
            }
        }
        return urls;
    }

    function isAvatarImage(img) {
        if (!img || !img.closest) return false;
        if (img.closest('[class*="avatar"], [class*="user-photo"], [class*="profile-photo"]'))
            return true;
        const { w, h } = mediaElementSize(img);
        if (w > 0 && h > 0 && w <= 52 && h <= 52) return true;
        const cls = String(img.className || '') + ' '
            + String(img.parentElement && img.parentElement.className || '');
        return /avatar|user-photo|profile/i.test(cls);
    }

    function isPhotoGridImage(img) {
        return !!(img && img.closest
            && img.closest('[class*="photo"], [class*="album"], [class*="media"], [class*="grid"], [class*="thumb"]'));
    }

    function extractBackgroundImageUrls(root) {
        const urls = [];
        const seen = new Set();
        const push = (url, el) => {
            if (!isChatImageUrl(url, el) || seen.has(url)) return;
            seen.add(url);
            urls.push(url);
        };
        for (const el of root.querySelectorAll('[style*="background"]')) {
            if (el.closest('[class*="avatar"]')) continue;
            if (isInviteOrContactImage(el)) continue;
            const style = el.getAttribute('style') || '';
            const re = /url\(\s*['"]?([^'")]+)['"]?\s*\)/gi;
            let match;
            while ((match = re.exec(style)))
                push(match[1], el);
        }
        for (const el of root.querySelectorAll('[data-src], [data-url], [data-original], [data-thumb]')) {
            if (el.tagName === 'IMG' || el.tagName === 'VIDEO') continue;
            if (el.closest('[class*="avatar"]')) continue;
            push(el.getAttribute('data-src')
                || el.getAttribute('data-url')
                || el.getAttribute('data-original')
                || el.getAttribute('data-thumb'), el);
        }
        return urls;
    }

    function isCommunityCardImage(img) {
        if (!img || !img.closest) return false;
        if (isRoomPhotoImage(img)) return false;
        const skipSelectors = [
            '[class*="link"]', '[class*="preview"]', '[class*="og-"]',
            '[class*="share"]', '[class*="banner"]',
            '[class*="community"]', '[class*="group-info"]',
            '[class*="article"]', '[class*="rich-link"]'
        ];
        for (const sel of skipSelectors) {
            const box = img.closest(sel);
            if (!box) continue;
            const text = normalizeText(box.innerText || box.textContent || '');
            if (/cộng đồng|community|cho thuê chdv|link nhóm|tham gia|dự án/i.test(text))
                return true;
        }
        let el = img.parentElement;
        for (let depth = 0; el && depth < 5; depth++, el = el.parentElement) {
            const text = normalizeText(el.innerText || el.textContent || '');
            if (text.length > 180) break;
            if (/cộng đồng|community|link\s+nhóm|tham\s+gia\s+cộng\s+đồng|home\s*365/i.test(text))
                return true;
        }
        return false;
    }

    function isPinnedRegion(el) {
        if (!el || !el.closest) return false;
        return !!el.closest(
            '[class*="pin-msg"], [class*="PinMsg"], [class*="pinned-msg"],'
            + '[class*="pin-bar"], [class*="pinBar"], header [class*="pin"]');
    }

    function cardLocalText(el) {
        if (!el || !el.closest) return '';
        const box = el.closest(
            '[class*="link"], [class*="preview"], [class*="card"], [class*="share"],'
            + ' [class*="og-"], [class*="contact"], [class*="qr"], [class*="banner"]');
        const root = box || el.parentElement;
        const t = normalizeText((root && (root.innerText || root.textContent)) || '');
        if (t.length && t.length <= 280) return t;
        let node = el.parentElement;
        for (let depth = 0; node && depth < 5; depth++, node = node.parentElement) {
            const s = normalizeText(node.innerText || node.textContent || '');
            if (s.length > 220) break;
            if (s.length > 8) return s;
        }
        return t.slice(0, 280);
    }

    function isRoomPhotoImage(img) {
        if (!img || isAvatarImage(img)) return false;
        if (img.closest(
            '[class*="og-"], [class*="rich-link"], [class*="link-preview"],'
            + ' [class*="LinkPreview"]'))
            return false;
        const { w, h } = mediaElementSize(img);
        if (w >= 72 && h >= 72) return true;
        return isPhotoGridImage(img) && isSizedMessageMedia(img);
    }

    function isInviteOrContactImage(img) {
        if (!img || !img.closest) return false;
        const t = cardLocalText(img);
        if (/kết bạn|nhắn tin/i.test(t)) return true;
        if (isRoomPhotoImage(img)) return false;
        if (/zalo\.me|tham gia cộng đồng|bấm vào đây|cộng đồng/i.test(t)
            && !/giá\s*\d|\d+\s*tr\b|\d+tr\d|phòng\s+\d/i.test(t))
            return true;
        return isCommunityCardImage(img);
    }

    function hasRentalCore(text) {
        const t = normalizeText(text || '');
        return /(?:giá|cho thuê|phòng\s+\d|studio|duplex|mã phòng|địa chỉ|trống\s*(?:sẵn|phòng|\d)|full nội thất|\d+tr\d|\d+\s*tr\b|\b1pn\b|\b2pn\b|phí dv|pdv|\bbancol\b|(?:mã|ma)\s*[:\-–]?\s*\d{2,4}|tòa nhà|quy mô)/i.test(t);
    }

    function isClockOnlyText(text) {
        return /^\d{1,2}:\d{2}$/.test(normalizeText(text || ''));
    }

    function isRoomCodeCaption(text) {
        const t = normalizeText(text || '');
        if (!t) return false;
        const cleaned = t
            .replace(/\[hình ảnh\]/gi, ' ')
            .replace(/@all\b/gi, ' ')
            .replace(/(?:^|\s)\d{1,2}:\d{2}(?:\s|$)/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        if (!cleaned || cleaned.length > 48) return false;
        if (/^(?:[A-Za-z]{1,3}\d{2,4}[A-Za-z]?|\d{3,4})$/.test(cleaned))
            return true;
        const tokens = cleaned.split(' ').filter(Boolean);
        if (tokens.length > 4) return false;
        const codes = tokens.filter(x => /^[A-Za-z]{1,3}\d{2,4}[A-Za-z]?$/.test(x));
        const rest = tokens.filter(x => !/^[A-Za-z]{1,3}\d{2,4}[A-Za-z]?$/.test(x));
        return codes.length === 1 && rest.every(x => !/\d/.test(x) && x.length <= 24);
    }

    function isPromoCaption(text) {
        const t = normalizeText(text || '');
        if (!t || isClockOnlyText(t)) return false;
        if (/kết bạn|nhắn tin/i.test(t) && t.length < 240) return true;
        if (/zalo\.me\/g\/|tham gia cộng đồng|bấm vào đây để tham gia/i.test(t)
            && !hasRentalCore(t))
            return true;
        return false;
    }

    function isListingCaption(text) {
        const t = normalizeText(text || '');
        if (!t || isClockOnlyText(t) || isPromoCaption(t)) return false;
        return hasRentalCore(t) || isRoomCodeCaption(t);
    }

    function isBareSenderOrNoise(text) {
        const t = normalizeText(text || '');
        if (!t || isClockOnlyText(t)) return true;
        if (hasRentalCore(t) || isRoomCodeCaption(t) || isPromoCaption(t)) return false;
        return t.length <= 48;
    }

    function effectiveCaption(text) {
        if (isBareSenderOrNoise(text)) return '';
        return text;
    }

    function isPhotoCarrier(message) {
        return !!(message && message.images && message.images.length
            && !isListingCaption(message.text));
    }

    function isPromoBannerImage(img, item) {
        if (!img) return false;
        if (isPinnedRegion(img) || isPinnedRegion(item)) return true;
        if (isInviteOrContactImage(img)) return true;
        return false;
    }

    function extractMessageImages(item) {
        const urls = [];
        const seen = new Set();
        const push = (url) => {
            if (!url || seen.has(url)) return;
            seen.add(url);
            urls.push(url);
        };

        for (const img of item.querySelectorAll('img')) {
            if (isAvatarImage(img)) continue;
            const roomPhoto = isRoomPhotoImage(img);
            if (!roomPhoto && isPromoBannerImage(img, item)) continue;
            let url = resolveImageUrl(img);
            if (!url && isPhotoGridImage(img) && isSizedMessageMedia(img))
                url = img.currentSrc || img.src || img.getAttribute('data-src') || '';
            if (url) push(url);
        }

        for (const source of item.querySelectorAll('picture source[srcset], source[srcset]')) {
            if (isInviteOrContactImage(source)) continue;
            const url = parseSrcsetValue(source.srcset || source.getAttribute('srcset'));
            if (isChatImageUrl(url, source)) push(url);
        }

        for (const url of extractBackgroundImageUrls(item))
            push(url);

        return urls;
    }

    function probeMessagePaneImages() {
        const pane = getMessagePane();
        const imgs = pane ? pane.querySelectorAll('img') : [];
        const videos = pane ? pane.querySelectorAll('video') : [];
        const samples = [];
        let sized = 0;
        let resolved = 0;
        for (const img of imgs) {
            if (isAvatarImage(img)) continue;
            if (isSizedMessageMedia(img)) sized++;
            const url = resolveImageUrl(img);
            if (url) resolved++;
            if (samples.length < 8) {
                samples.push({
                    w: Math.round(mediaElementSize(img).w),
                    h: Math.round(mediaElementSize(img).h),
                    src: String(img.src || '').slice(0, 120),
                    dataSrc: String(img.getAttribute('data-src') || '').slice(0, 120),
                    resolved: String(url || '').slice(0, 120),
                    grid: isPhotoGridImage(img)
                });
            }
        }
        return {
            imgTotal: imgs.length,
            videoTotal: videos.length,
            sized,
            resolved,
            samples,
            selector: lastDomDiagnostics.matchedSelector
        };
    }

    function extractMessageTimeMs(item) {
        const nodes = [
            item,
            ...item.querySelectorAll(
                'time, [data-time], [data-timestamp], [datetime], [class*="time"]')
        ];
        for (const node of nodes) {
            if (!node.getAttribute) continue;
            for (const attr of ['data-timestamp', 'datetime', 'data-time']) {
                const value = String(node.getAttribute(attr) || '').trim();
                if (!value) continue;
                if (/^\d{13}$/.test(value)) return Number(value);
                if (/^\d{10}$/.test(value)) return Number(value) * 1000;
                const parsed = Date.parse(value);
                if (!Number.isNaN(parsed)) return parsed;
            }
        }
        const clock = String(item.innerText || '').match(/\b(\d{1,2}):(\d{2})\b/);
        if (clock) {
            const now = new Date();
            return new Date(
                now.getFullYear(), now.getMonth(), now.getDate(),
                Number(clock[1]), Number(clock[2]), 0, 0
            ).getTime();
        }
        return 0;
    }

    function collectMessages() {
        const items = findMessageElements();
        const messages = [];
        for (const item of items) {
            if (isPinnedRegion(item)) continue;
            const text = extractMessageText(item);
            const images = extractMessageImages(item);
            const videos = extractVideoUrls(item);
            if (!text && !images.length && !videos.length) continue;
            const hash = fnvHash(text + images.join('|') + videos.join('|'));
            const nestedDuplicate = messages.some(message =>
                message.hash === hash &&
                (message.element.contains(item) || item.contains(message.element))
            );
            if (nestedDuplicate) continue;
            messages.push({
                element: item,
                text,
                images,
                videos,
                timeMs: extractMessageTimeMs(item),
                hash
            });
        }
        return messages;
    }

    function takeNewestMessages(items, maxMessages) {
        const limit = Number(maxMessages);
        if (!Number.isFinite(limit) || limit <= 0 || items.length <= limit)
            return items;
        return items.slice(-limit);
    }

    function findUnreadDividerElement() {
        const pane = getMessagePane();
        if (!pane) return null;
        const re = /^(?:[-–—•\s]*)(?:\d+\s+)?(?:tin nhắn chưa đọc|tin chưa đọc|unread messages)(?:\s*[-–—•]*)?$/i;
        for (const el of pane.querySelectorAll('div, span, p, strong')) {
            if (isExcludedElement(el) || isPinnedRegion(el)) continue;
            if (el.closest('[class*="rich-text"], [class*="message-text"], [class*="text-message"]'))
                continue;
            const t = normalizeText(el.innerText || el.textContent || '');
            if (t.length < 8 || t.length > 40) continue;
            if (re.test(t)) return el;
        }
        return null;
    }

    function indexAfterUnreadDivider(messages) {
        const divider = findUnreadDividerElement();
        if (!divider || !messages.length) return -1;
        for (let i = 0; i < messages.length; i++) {
            const el = messages[i] && messages[i].element;
            if (!el || !el.isConnected) continue;
            if (divider === el || divider.contains(el)) return i;
            const pos = divider.compareDocumentPosition(el);
            if (pos & Node.DOCUMENT_POSITION_FOLLOWING) return i;
        }
        return -1;
    }

    function sliceUnreadToNewest(messages, maxBubbles) {
        return takeNewestMessages(messages, maxBubbles);
    }

    async function collectUnreadToNewestWindow(maxBubbles) {
        const pane = getMessagePane();
        const scrollable = pane
            ? (pane.closest('[class*="scroll"]') || pane)
            : null;
        const map = new Map();
        const ordered = [];
        const ingest = (where) => {
            const fresh = [];
            for (const m of collectMessages()) {
                const prev = map.get(m.hash);
                if (prev) {
                    if (m.images.length > prev.images.length
                        || (m.videos || []).length > (prev.videos || []).length) {
                        map.set(m.hash, m);
                        const idx = ordered.indexOf(prev);
                        if (idx >= 0) ordered[idx] = m;
                    }
                    continue;
                }
                let upgraded = false;
                for (const [hash, old] of map.entries()) {
                    if ((old.text || '') === (m.text || '')
                        && (m.images.length > old.images.length
                            || (m.videos || []).length > (old.videos || []).length)) {
                        map.delete(hash);
                        map.set(m.hash, m);
                        const idx = ordered.indexOf(old);
                        if (idx >= 0) ordered[idx] = m;
                        upgraded = true;
                        break;
                    }
                }
                if (upgraded) continue;
                map.set(m.hash, m);
                fresh.push(m);
            }
            if (where === 'up')
                ordered.unshift(...fresh);
            else
                ordered.push(...fresh);
            return fresh.length;
        };

        const hydrate = async () => {
            const paneEl = getMessagePane();
            if (!paneEl) return;
            let n = 0;
            for (const img of paneEl.querySelectorAll('img')) {
                if (isAvatarImage(img) || resolveImageUrl(img)) continue;
                if (!isSizedMessageMedia(img) && !isPhotoGridImage(img)) continue;
                try {
                    img.scrollIntoView({ block: 'nearest', behavior: 'instant' });
                } catch (_) { /* ignore */ }
                n++;
                if (n >= 8) break;
            }
            if (n) await sleep(160);
        };

        let divider = 0;
        if (scrollable) {
            scrollable.scrollTop = scrollable.scrollHeight;
            await sleep(250);
        }
        await hydrate();
        ingest('down');
        if (findUnreadDividerElement())
            divider = 1;

        if (scrollable) {
            for (let step = 0; step < 12; step++) {
                if (ordered.length >= maxBubbles) break;
                if (findUnreadDividerElement()) {
                    divider = 1;
                    ingest('up');
                    break;
                }
                if (scrollable.scrollTop <= 2) break;
                scrollable.scrollTop = Math.max(
                    0, scrollable.scrollTop - Math.max(120, scrollable.clientHeight * 0.85));
                await sleep(220);
                await hydrate();
                ingest('up');
            }
            scrollable.scrollTop = scrollable.scrollHeight;
            await sleep(180);
            await hydrate();
            ingest('down');
        }

        const windowed = takeNewestMessages(ordered, maxBubbles);
        return {
            ordered,
            windowed,
            collected: ordered.length,
            divider,
            imageOnly: windowed.filter(m => !effectiveCaption(m.text) && m.images.length).length,
            rawImgs: windowed.reduce((n, m) => n + (m.images || []).length, 0)
        };
    }

    const MAX_IMAGE_TEXT_GAP_MS = 90 * 1000;

    function nearestTextByTime(imageIdx, textIndices, messages) {
        const img = messages[imageIdx];
        let best = -1;
        let bestDt = Infinity;
        let bestDom = Infinity;
        for (const ti of textIndices) {
            const text = messages[ti];
            const dom = Math.abs(imageIdx - ti);
            let dt = Infinity;
            if (img.timeMs && text.timeMs)
                dt = Math.abs(img.timeMs - text.timeMs);
            else
                dt = dom * 60000;
            if (dt < bestDt || (dt === bestDt && dom < bestDom)) {
                bestDt = dt;
                bestDom = dom;
                best = ti;
            }
        }
        if (best < 0) return -1;
        const text = messages[best];
        if (img.timeMs && text.timeMs && bestDt > MAX_IMAGE_TEXT_GAP_MS)
            return -1;
        return best;
    }

    function gridRoot(message) {
        const el = message && message.element;
        if (!el || !el.closest) return null;
        return el.closest(
            '[class*="album"], [class*="photo-grid"], [class*="photogrid"],'
            + ' [class*="media-grid"], [class*="image-grid"]') || el;
    }

    function imageRuns(messages) {
        const runs = [];
        let run = [];
        let runRoot = null;
        for (let i = 0; i < messages.length; i++) {
            if (isPhotoCarrier(messages[i])) {
                const root = gridRoot(messages[i]);
                if (run.length && runRoot && root && root !== runRoot) {
                    runs.push(run);
                    run = [];
                }
                run.push(i);
                runRoot = root || runRoot;
            } else if (run.length) {
                runs.push(run);
                run = [];
                runRoot = null;
            }
        }
        if (run.length)
            runs.push(run);
        return runs;
    }

    function nearestTextForRun(indices, textIndices, messages) {
        const mid = indices[Math.floor(indices.length / 2)];
        const hasTime = indices.some(i => messages[i].timeMs)
            && textIndices.some(ti => messages[ti].timeMs);
        if (hasTime)
            return nearestTextByTime(mid, textIndices, messages);
        const first = indices[0];
        const last = indices[indices.length - 1];
        let best = -1;
        let bestGap = Infinity;
        for (const ti of textIndices) {
            const gap = ti < first ? first - ti : (ti > last ? ti - last : 0);
            if (gap <= 3 && gap < bestGap) {
                bestGap = gap;
                best = ti;
            }
        }
        return best;
    }

    function associateImagesWithText(messages) {
        const textIndices = [];
        for (let i = 0; i < messages.length; i++) {
            if (isListingCaption(messages[i].text)) textIndices.push(i);
        }
        if (!textIndices.length) {
            for (let i = 0; i < messages.length; i++) {
                const cap = effectiveCaption(messages[i].text);
                if (cap && !isPromoCaption(cap)) textIndices.push(i);
            }
        }

        const imageOwner = new Map();
        let droppedFar = 0;
        for (const run of imageRuns(messages)) {
            const target = nearestTextForRun(run, textIndices, messages);
            if (target >= 0) {
                for (const i of run)
                    imageOwner.set(i, target);
            } else {
                droppedFar += run.length;
            }
        }

        const ownedBefore = new Map();
        const ownedAfter = new Map();
        for (const [imgIdx, ti] of imageOwner.entries()) {
            if (imgIdx < ti) {
                if (!ownedBefore.has(ti)) ownedBefore.set(ti, []);
                ownedBefore.get(ti).push(imgIdx);
            } else if (imgIdx > ti) {
                if (!ownedAfter.has(ti)) ownedAfter.set(ti, []);
                ownedAfter.get(ti).push(imgIdx);
            }
        }

        const result = [];
        for (const ti of textIndices) {
            const message = messages[ti];
            const before = ownedBefore.get(ti) || [];
            const after = ownedAfter.get(ti) || [];
            let keep = [];
            if (before.length && after.length)
                keep = before;
            else
                keep = before.concat(after);

            const images = [...message.images];
            const videos = [...(message.videos || [])];
            if (!images.length) {
                for (const idx of keep) {
                    images.push(...messages[idx].images);
                    videos.push(...(messages[idx].videos || []));
                }
            }
            const hash = fnvHash(message.text + images.join('|') + videos.join('|'));
            const hadBefore = keep.some(idx => idx < ti);
            const hadAfter = keep.some(idx => idx > ti);
            const forward_eligible = images.length > 0
                && (message.images.length > 0 || hadBefore || hadAfter);

            result.push({
                text: message.text,
                images,
                videos,
                hash,
                message_hash: hash,
                dom_index: ti,
                forward_eligible,
                element: message.element,
                droppedFar
            });
        }
        return result;
    }

    function minTimeDelta(textMsg, indices, messages) {
        if (!textMsg.timeMs) return Infinity;
        let best = Infinity;
        for (const i of indices) {
            if (!messages[i].timeMs) continue;
            best = Math.min(best, Math.abs(messages[i].timeMs - textMsg.timeMs));
        }
        return best;
    }

    async function ensureLazyImagesLoaded() {
        const pane = getMessagePane();
        if (!pane) return;
        const scrollable = pane.closest('[class*="scroll"]') || pane;
        if (!scrollable) return;
        const originalTop = scrollable.scrollTop;
        if (scrollable.scrollHeight > scrollable.clientHeight + 8) {
            scrollable.scrollTop = scrollable.scrollHeight;
            await sleep(400);
            const steps = 5;
            for (let step = steps; step >= 0; step--) {
                scrollable.scrollTop = Math.round(
                    (scrollable.scrollHeight - scrollable.clientHeight) * (step / steps));
                await sleep(200);
            }
        }
        const items = findMessageElements();
        for (let i = items.length - 1; i >= 0 && i >= items.length - 12; i--) {
            try {
                items[i].scrollIntoView({ block: 'center', behavior: 'instant' });
            } catch (_) { /* ignore */ }
            await sleep(160);
        }
        scrollable.scrollTop = originalTop;
        await sleep(300);
    }

    function buildScanResultFromAssociated(messages, maxMessages) {
        const lines = messages.map(m => m.text).filter(Boolean);
        const imageTotal = messages.reduce((sum, m) => sum + m.images.length, 0);
        return {
            group: getConversationTitle(),
            text: lines.join('\n'),
            image_total: imageTotal,
            image_probe: probeMessagePaneImages(),
            messages: messages.map(m => ({
                text: m.text,
                images: m.images,
                videos: m.videos || [],
                hash: m.hash,
                message_hash: m.message_hash || m.hash,
                forward_eligible: !!m.forward_eligible
            })),
            message_count: messages.length,
            max_messages: Number(maxMessages) > 0 ? Number(maxMessages) : 0,
            collected: lastScanDebug.collected || messages.length,
            windowed: lastScanDebug.windowed || messages.length,
            divider: lastScanDebug.divider || 0,
            image_only: lastScanDebug.imageOnly || 0,
            raw_imgs: lastScanDebug.rawImgs || 0,
            dom: lastDomDiagnostics
        };
    }

    function buildScanResult(collected, maxMessages) {
        const windowed = sliceUnreadToNewest(collected, maxMessages);
        const associated = associateImagesWithText(windowed);
        return buildScanResultFromAssociated(associated, maxMessages);
    }

    async function scanConversationAsync(maxMessages) {
        const limit = Number(maxMessages) > 0 ? Number(maxMessages) : 50;
        let pack = await collectUnreadToNewestWindow(limit);
        if (!pack.windowed.length) {
            await ensureLazyImagesLoaded();
            pack = await collectUnreadToNewestWindow(limit);
        }
        lastScanDebug = {
            collected: pack.collected,
            windowed: pack.windowed.length,
            divider: pack.divider,
            imageOnly: pack.imageOnly,
            rawImgs: pack.rawImgs
        };
        const associated = associateImagesWithText(pack.windowed);
        return buildScanResultFromAssociated(associated, limit);
    }

    function scanConversation(maxMessages) {
        const limit = Number(maxMessages) > 0 ? Number(maxMessages) : 50;
        return buildScanResult(collectMessages(), limit);
    }

    function probeSidebarSearch() {
        const vw = window.innerWidth || document.documentElement.clientWidth || 1200;
        const maxRight = vw * 0.52;
        const found = findSidebarSearchInput();
        const candidates = [];
        for (const el of document.querySelectorAll(
            'input, [contenteditable="true"], textarea')) {
            if (isSidebarSearchExcluded(el)) continue;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0 || rect.right > maxRight) continue;
            candidates.push({
                tag: el.tagName,
                placeholder: (el.getAttribute('placeholder') || '').slice(0, 60),
                ariaLabel: (el.getAttribute('aria-label') || '').slice(0, 60),
                top: Math.round(rect.top),
                right: Math.round(rect.right)
            });
            if (candidates.length >= 8) break;
        }
        return {
            found: !!found,
            tag: found ? found.tagName : '',
            placeholder: found ? (found.getAttribute('placeholder') || '') : '',
            candidates
        };
    }

    function dumpDom() {
        const messages = collectMessages();
        return {
            role: BRIDGE.role,
            group: getConversationTitle(),
            matchedSelector: lastDomDiagnostics.matchedSelector,
            messageCount: messages.length,
            imageProbe: probeMessagePaneImages(),
            sampleTexts: messages.slice(-5).map(m => ({
                text: m.text.slice(0, 120),
                imageCount: m.images.length
            })),
            search: probeSidebarSearch()
        };
    }

    function findUnreadGroups(knownGroups = []) {
        const items = [];
        for (const sel of SELECTORS.sidebarItem) {
            document.querySelectorAll(sel).forEach(el => items.push(el));
        }
        const unread = [];
        const seen = new Set();
        let badgeCandidates = 0;
        for (const item of items) {
            const nameEl = item.querySelector('[class*="title"], [class*="name"]') || item;
            const name = normalizeText(nameEl.innerText || nameEl.textContent);
            if (!name || seen.has(name)) continue;
            seen.add(name);
            const badge = qs(SELECTORS.unreadBadge, item);
            const badgeText = badge ? normalizeText(badge.innerText || badge.textContent) : '';
            if (badge) badgeCandidates++;
            const numericBadge = /^\d{1,3}$/.test(badgeText);
            const hasUnread = badge && (
                numericBadge ||
                /tin nhắn mới|chưa đọc|unread/i.test(badgeText)
            );
            if (hasUnread) unread.push({
                name,
                count: numericBadge ? Math.max(1, Number.parseInt(badgeText, 10)) : 1
            });
        }
        const knownKeys = new Set(
            knownGroups.map(name => normalizeText(name).toLocaleLowerCase('vi'))
        );
        const visibleKnown = [...seen].filter(name =>
            knownKeys.has(normalizeText(name).toLocaleLowerCase('vi'))
        ).length;
        const diagnostics = {
            sidebarItems: items.length,
            uniqueNames: seen.size,
            badgeCandidates,
            unreadCount: unread.length,
            knownCount: knownKeys.size,
            visibleKnown
        };
        return { items: unread, diagnostics };
    }

    async function focusCompose() {
        const box = qs(SELECTORS.composeBox);
        if (!box) throw new Error('Không tìm thấy ô soạn tin Zalo Web.');
        box.focus();
        box.click();
        await sleep(120);
        return true;
    }

    function isMediaHit(el) {
        if (!el) return false;
        return !!(el.closest
            && el.closest('img, video, picture, canvas, a[href], [class*="photo"], [class*="image"], [class*="album"], [class*="media"], [class*="viewer"]'));
    }

    async function focusMessagePane() {
        // Close an image lightbox if a previous click opened one.
        dismissBrowserUi();
        const header = qs([
            '[class*="chat-header"]',
            '[class*="header-chat"]',
            '[class*="conv-header"]'
        ]);
        const title = qs(SELECTORS.conversationTitle);
        const pane = getMessagePane();
        const safe = header || title;
        let via = 'none';
        if (safe) {
            via = header ? 'header' : 'title';
            try { safe.focus({ preventScroll: true }); } catch (_) {
                try { safe.focus(); } catch (__) { /* ignore */ }
            }
            const hit = safe;
            if (!isMediaHit(hit))
                hit.click();
            else
                via += '_media_skip';
        } else if (pane && pane !== document.body) {
            via = 'pane';
            try { pane.focus({ preventScroll: true }); } catch (_) {
                try { pane.focus(); } catch (__) { /* ignore */ }
            }
            const rect = pane.getBoundingClientRect();
            const x = rect.left + Math.min(36, Math.max(8, rect.width * 0.08));
            const y = rect.top + 10;
            const hit = document.elementFromPoint(x, y);
            if (hit && !isMediaHit(hit) && pane.contains(hit))
                hit.click();
            else if (hit && isMediaHit(hit))
                via = 'pane_media_blocked';
        }
        await sleep(80);
        dismissBrowserUi();
        return { ok: true, via };
    }

    function getSidebarRoot() {
        return qs([
            '[class*="left-side"]',
            '[class*="sidebar"]',
            '[class*="conv-list"]',
            'nav[class*="side"]'
        ]) || document.body;
    }

    function collectGroupLabels(selectors, root = document) {
        const labels = [];
        const seen = new Set();
        for (const sel of selectors) {
            for (const item of root.querySelectorAll(sel)) {
                const label = normalizeText(item.innerText || item.textContent);
                if (!label || seen.has(label)) continue;
                seen.add(label);
                labels.push({ item, label });
            }
        }
        return labels;
    }

    function dismissBrowserUi() {
        for (let i = 0; i < 2; i++) {
            document.dispatchEvent(new KeyboardEvent('keydown', {
                key: 'Escape', code: 'Escape', keyCode: 27, bubbles: true
            }));
        }
    }

    function isSidebarSearchExcluded(el) {
        if (!el) return true;
        if (el.closest('[class*="chat-input"]') || el.closest('[class*="compose"]')) return true;
        const pane = getMessagePane();
        if (pane && pane !== document.body && pane.contains(el)) return true;
        if (el.closest(SELECTORS.composeBox[0])) return true;
        return false;
    }

    function findSidebarSearchInput() {
        const vw = window.innerWidth || document.documentElement.clientWidth || 1200;
        const maxRight = vw * 0.52;

        for (const sel of SELECTORS.sidebarSearch) {
            for (const el of document.querySelectorAll(sel)) {
                if (isSidebarSearchExcluded(el)) continue;
                const rect = el.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0) continue;
                if (rect.right <= maxRight) return el;
            }
        }

        for (const el of document.querySelectorAll(
            'input[type="text"], input[type="search"], input:not([type]), [contenteditable="true"]')) {
            if (isSidebarSearchExcluded(el)) continue;
            const rect = el.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0 || rect.right > maxRight) continue;
            const hint = [
                el.getAttribute('placeholder') || '',
                el.getAttribute('aria-label') || '',
                el.getAttribute('title') || ''
            ].join(' ').toLowerCase();
            if (/tìm|tim|search/.test(hint) || rect.top < 220)
                return el;
        }
        return null;
    }

    async function ensureSidebarSearchVisible() {
        let search = findSidebarSearchInput();
        if (search) return search;

        const sidebar = getSidebarRoot();
        const triggers = sidebar.querySelectorAll(
            'button[class*="search"], [class*="search"] button, [class*="search-icon"],'
            + '[aria-label*="Tìm"], [aria-label*="tim"], [title*="Tìm"], [title*="tim"]');
        for (const btn of triggers) {
            btn.click();
            await sleep(500);
            search = findSidebarSearchInput();
            if (search) return search;
        }
        return findSidebarSearchInput();
    }

    async function typeSearchQuery(search, text) {
        search.focus();
        search.click();
        await sleep(120);
        if (search.isContentEditable) {
            search.textContent = '';
            search.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'deleteContentBackward' }));
            await sleep(80);
            search.textContent = text;
            search.dispatchEvent(new InputEvent('input', {
                bubbles: true,
                inputType: 'insertText',
                data: text
            }));
            search.dispatchEvent(new Event('change', { bubbles: true }));
            return;
        }
        setControlledInputValue(search, '');
        await sleep(80);
        setControlledInputValue(search, text);
    }

    async function tryOpenMatchingItem(items, groupName) {
        for (const entry of items) {
            if (!groupNamesMatch(entry.label, groupName))
                continue;
            entry.item.scrollIntoView({ block: 'nearest' });
            // Search results can be anchors with target=_blank. Force this
            // bot-owned navigation to stay in the current Zalo tab.
            const anchor = entry.item.matches?.('a[href]')
                ? entry.item
                : entry.item.querySelector?.('a[href]');
            const previousTarget = anchor ? anchor.getAttribute('target') : null;
            if (anchor) anchor.setAttribute('target', '_self');
            entry.item.click();
            if (anchor) {
                if (previousTarget === null) anchor.removeAttribute('target');
                else anchor.setAttribute('target', previousTarget);
            }
            await sleep(1200);
            const title = getConversationTitle();
            if (groupNamesMatch(title, groupName))
                return { ok: true, group: title };
        }
        return null;
    }

    async function navigateToGroup(groupName) {
        if (!groupName) throw new Error('Tên nhóm rỗng.');
        dismissBrowserUi();
        await sleep(200);
        const search = await ensureSidebarSearchVisible();
        if (!search) throw new Error('Không tìm thấy ô tìm kiếm sidebar Zalo.');

        search.scrollIntoView({ block: 'nearest' });
        await typeSearchQuery(search, groupName);
        await sleep(1200);

        const sidebarRoot = getSidebarRoot();
        let opened = await tryOpenMatchingItem(
            collectGroupLabels(SELECTORS.sidebarItem, sidebarRoot),
            groupName
        );
        if (opened) return opened;

        opened = await tryOpenMatchingItem(
            collectGroupLabels(SELECTORS.searchResultItem, document),
            groupName
        );
        if (opened) return opened;

        opened = await tryOpenMatchingItem(
            collectGroupLabels(SELECTORS.sidebarItem, document),
            groupName
        );
        if (opened) return opened;

        search.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
        await sleep(1200);
        const title = getConversationTitle();
        if (groupNamesMatch(title, groupName))
            return { ok: true, group: title };
        throw new Error('Không mở được nhóm: ' + groupName);
    }

    function findAssociatedMessage(sourceGroup, messageHash, roomCode) {
        const messages = associateImagesWithText(collectMessages());
        if (messageHash) {
            const exact = messages.find(m => m.hash === messageHash || m.message_hash === messageHash);
            if (exact) return exact;
        }
        const needle = (roomCode || '').toLowerCase().trim();
        if (needle) {
            const byCode = messages.find(m => m.text.toLowerCase().includes(needle));
            if (byCode) return byCode;
        }
        return null;
    }

    function clickForwardMenuItem() {
        const items = document.querySelectorAll(
            '[role="menuitem"], [class*="menu"] li, [class*="context-menu"] *,'
            + '[class*="popup"] *, button, div[tabindex="0"]');
        for (const el of items) {
            const label = normalizeText(el.innerText || el.textContent || el.getAttribute('aria-label') || '');
            if (/chuyển tiếp|chuyen tiep|forward/i.test(label)) {
                el.click();
                return true;
            }
        }
        return false;
    }

    async function pickForwardTarget(targetGroup) {
        await sleep(400);
        const search = findSidebarSearchInput()
            || document.querySelector(
                '[class*="forward"] input, [class*="modal"] input, [class*="popup"] input[type="text"]');
        if (!search) throw new Error('Không tìm thấy ô chọn nhóm khi forward.');
        await typeSearchQuery(search, targetGroup);
        await sleep(900);
        const opened = await tryOpenMatchingItem(
            collectGroupLabels(
                [...SELECTORS.searchResultItem, ...SELECTORS.sidebarItem],
                document
            ),
            targetGroup
        );
        if (!opened) {
            search.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            await sleep(900);
        }
        const sendBtn = [...document.querySelectorAll('button, [role="button"], div[tabindex="0"]')]
            .find(el => /gửi|gui|send|chuyển|chuyen/i.test(
                normalizeText(el.innerText || el.textContent || el.getAttribute('aria-label') || '')));
        if (sendBtn) {
            sendBtn.click();
            await sleep(800);
        }
        const title = getConversationTitle();
        if (!groupNamesMatch(title, targetGroup))
            throw new Error('Forward xong nhưng chưa mở nhóm output: ' + targetGroup);
        return { ok: true, group: title };
    }

    async function forwardMessageElement(element, targetGroup) {
        if (!element) throw new Error('Không có DOM bubble để forward.');
        element.scrollIntoView({ block: 'center' });
        await sleep(250);
        element.dispatchEvent(new MouseEvent('contextmenu', {
            bubbles: true, cancelable: true, button: 2
        }));
        await sleep(350);
        if (!clickForwardMenuItem()) {
            element.click();
            await sleep(150);
            element.dispatchEvent(new MouseEvent('contextmenu', {
                bubbles: true, cancelable: true, button: 2
            }));
            await sleep(350);
            if (!clickForwardMenuItem())
                throw new Error('Không mở được menu Chuyển tiếp trên bubble tin.');
        }
        return pickForwardTarget(targetGroup);
    }

    async function forwardMessageToGroup(sourceGroup, targetGroup, messageHash, roomCode) {
        if (!sourceGroup || !targetGroup)
            throw new Error('Thiếu source_group hoặc target_group khi forward.');
        await navigateToGroup(sourceGroup);
        await sleep(500);
        const match = findAssociatedMessage(sourceGroup, messageHash, roomCode);
        if (!match) throw new Error('Không tìm thấy tin để forward: ' + (messageHash || roomCode || ''));
        if (!match.forward_eligible)
            throw new Error('Tin không có ảnh kề — dùng archive paste thay forward.');
        const result = await forwardMessageElement(match.element, targetGroup);
        return { ok: true, forwarded: 1, group: result.group, message_hash: match.hash };
    }

    function requestImageBlob(url) {
        if (url.startsWith('blob:')) {
            return fetch(url).then(response => {
                if (!response.ok) throw new Error('Fetch ảnh thất bại: ' + response.status);
                return response.blob();
            });
        }
        return new Promise((resolve, reject) => {
            GM_xmlhttpRequest({
                method: 'GET',
                url,
                responseType: 'blob',
                timeout: 15000,
                onload(response) {
                    if (response.status < 200 || response.status >= 300) {
                        reject(new Error('Tải ảnh thất bại: HTTP ' + response.status));
                        return;
                    }
                    resolve(response.response);
                },
                onerror: () => reject(new Error('Không tải được ảnh từ CDN Zalo.')),
                ontimeout: () => reject(new Error('Timeout khi tải ảnh từ CDN Zalo.'))
            });
        });
    }

    function imageUrlKind(url) {
        const value = String(url || '').toLowerCase();
        if (value.startsWith('blob:')) return 'blob';
        if (value.startsWith('data:')) return 'data';
        if (value.startsWith('https://')) return 'https';
        if (value.startsWith('http://')) return 'http';
        return 'other';
    }

    async function toClipboardPng(blob) {
        if (String(blob.type || '').toLowerCase() === 'image/png')
            return blob;
        const bitmap = await createImageBitmap(blob);
        const canvas = document.createElement('canvas');
        canvas.width = bitmap.width;
        canvas.height = bitmap.height;
        const context = canvas.getContext('2d');
        if (!context) {
            bitmap.close();
            throw new Error('Không tạo được canvas chuyển ảnh sang PNG.');
        }
        context.drawImage(bitmap, 0, 0);
        bitmap.close();
        const png = await new Promise((resolve, reject) => {
            canvas.toBlob(
                value => value ? resolve(value) : reject(
                    new Error('Không chuyển được ảnh sang PNG.')),
                'image/png'
            );
        });
        return png;
    }

    async function copyImageBlobToClipboard(url) {
        const blob = await requestImageBlob(url);
        const png = await toClipboardPng(blob);
        await navigator.clipboard.write([
            new ClipboardItem({ 'image/png': png })
        ]);
        return true;
    }

    function blobToBase64(blob) {
        return new Promise((resolve, reject) => {
            if (blob.size > 12 * 1024 * 1024) {
                reject(new Error('Ảnh vượt giới hạn 12 MB.'));
                return;
            }
            const reader = new FileReader();
            reader.onload = () => {
                const value = String(reader.result || '');
                const comma = value.indexOf(',');
                resolve(comma >= 0 ? value.slice(comma + 1) : value);
            };
            reader.onerror = () => reject(new Error('Không đọc được blob ảnh.'));
            reader.readAsDataURL(blob);
        });
    }

    async function fetchImageData(url) {
        if (!url) throw new Error('URL ảnh rỗng.');
        const blob = await requestImageBlob(url);
        return {
            data_base64: await blobToBase64(blob),
            mime: blob.type || 'image/png',
            size: blob.size,
            url
        };
    }

    async function findImagesNearAnchorDom(anchor, limit = 6) {
        const needle = (anchor || '').toLowerCase().trim();
        if (!needle) return [];
        const items = findMessageElements();
        let anchorIdx = -1;
        for (let i = items.length - 1; i >= 0; i--) {
            if (extractMessageText(items[i]).toLowerCase().includes(needle)) {
                anchorIdx = i;
                break;
            }
        }
        if (anchorIdx < 0) return [];
        const urls = [];
        const seen = new Set();
        const pushAll = (list) => {
            for (const url of list) {
                if (!url || seen.has(url)) continue;
                seen.add(url);
                urls.push(url);
            }
        };
        for (let j = Math.max(0, anchorIdx - 1);
            j <= Math.min(items.length - 1, anchorIdx + 2); j++) {
            const nearbyText = extractMessageText(items[j]);
            if (isPromoCaption(nearbyText)) continue;
            try {
                items[j].scrollIntoView({ block: 'center', behavior: 'instant' });
            } catch (_) { /* ignore */ }
            await sleep(180);
            pushAll(extractMessageImages(items[j]));
        }
        return urls.slice(0, limit).map(url => ({ url, text: '' }));
    }

    async function findImagesNearAnchor(anchor, limit = 16, messageHash = '') {
        const messages = associateImagesWithText(collectMessages());
        const cap = Number(limit) > 0 ? Number(limit) : 16;
        if (messageHash) {
            const exact = messages.find(m =>
                m.hash === messageHash || m.message_hash === messageHash);
            if (exact && exact.images.length) {
                return exact.images.slice(0, cap).map(url => ({
                    url,
                    text: exact.text
                }));
            }
        }

        const needle = (anchor || '').toLowerCase().trim();
        if (needle) {
            for (let i = messages.length - 1; i >= 0; i--) {
                const msg = messages[i];
                if (msg.text.toLowerCase().includes(needle) && msg.images.length) {
                    return msg.images.slice(0, cap).map(url => ({
                        url,
                        text: msg.text
                    }));
                }
            }
        }
        return [];
    }

    async function listImagesForAnchor(anchor, limit = 6, messageHash = '') {
        const found = await findImagesNearAnchor(anchor, limit, messageHash);
        return { count: found.length, urls: found.map(item => item.url) };
    }

    async function setClipboardImageFromBase64(dataBase64, mime) {
        const value = String(dataBase64 || '').replace(/\s/g, '');
        if (!value) throw new Error('data_base64 rỗng.');
        const binary = atob(value);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        const type = mime || 'image/png';
        const png = await toClipboardPng(new Blob([bytes], { type }));
        await navigator.clipboard.write([
            new ClipboardItem({ 'image/png': png })
        ]);
        return { ok: true, mime: 'image/png', size: png.size };
    }

    async function copyImageByUrl(url) {
        if (!url) throw new Error('URL ảnh rỗng.');
        await copyImageBlobToClipboard(url);
        return { ok: true, url };
    }

    async function copyVideoByUrl(url) {
        if (!url) throw new Error('URL video rỗng.');
        const blob = await requestImageBlob(url);
        const type = blob.type && blob.type.startsWith('video/')
            ? blob.type : 'video/mp4';
        await navigator.clipboard.write([
            new ClipboardItem({ [type]: blob })
        ]);
        return { ok: true, url, mime: type, size: blob.size };
    }

    async function scrollToAnchor(anchor) {
        const needle = (anchor || '').toLowerCase();
        if (!needle) return false;
        for (const item of findMessageElements()) {
            if (extractMessageText(item).toLowerCase().includes(needle)) {
                item.scrollIntoView({ block: 'center' });
                await sleep(300);
                return true;
            }
        }
        return false;
    }

    async function replyCommand(cmd) {
        const commandId = cmd && cmd.id ? cmd.id : '';
        try {
            const result = await runCommand(cmd);
            await http('POST', '/api/command-result', {
                id: commandId,
                ok: true,
                result
            });
        } catch (err) {
            if (!commandId) return;
            try {
                await http('POST', '/api/command-result', {
                    id: commandId,
                    ok: false,
                    error: String(err.message || err)
                });
            } catch (_) { /* ignore */ }
        }
    }

    async function registerRole() {
        try {
            applyRoleTitle();
            const resp = await http('POST', '/api/register', {
                role: 'bot',
                version: SCRIPT_VERSION,
                title: document.title,
                url: location.href,
                ts: Date.now()
            });
            const cmd = resp.body && resp.body.command;
            if (cmd && cmd.action === 'ping')
                await replyCommand(cmd);
        } catch (_) { /* bridge offline */ }
    }

    async function refreshPublicConfig() {
        try {
            const resp = await http('GET', '/api/config');
            const groups = resp.body && resp.body.output_groups;
            if (Array.isArray(groups))
                outputGroupNames = groups.map(name => String(name || ''));
        } catch (_) { /* bridge offline */ }
    }

    async function runCommand(cmd) {
        switch (cmd.action) {
            case 'ping':
                return { ok: true, role: 'bot', title: document.title, url: location.href };
            case 'navigate':
                return await navigateToGroup(cmd.group);
            case 'scan':
                return await scanConversationAsync(cmd.max_messages);
            case 'probe_images':
                await ensureLazyImagesLoaded();
                return probeMessagePaneImages();
            case 'dump_dom':
                return dumpDom();
            case 'title':
                return { group: getConversationTitle() };
            case 'unread':
                {
                    const unread = findUnreadGroups(cmd.known_groups || []);
                    return {
                        groups: unread.items.map(item => item.name),
                        items: unread.items,
                        diagnostics: unread.diagnostics
                    };
                }
            case 'focus_compose':
                await focusCompose();
                return { ok: true };
            case 'focus_pane':
                return await focusMessagePane();
            case 'forward_message':
                return await forwardMessageToGroup(
                    cmd.source_group, cmd.target_group, cmd.message_hash, cmd.room_code || '');
            case 'find_images':
                if (cmd.anchor) await scrollToAnchor(cmd.anchor);
                return await listImagesForAnchor(
                    cmd.anchor, cmd.limit || 16, cmd.message_hash || '');
            case 'copy_image':
                return await copyImageByUrl(cmd.url);
            case 'copy_video':
                return await copyVideoByUrl(cmd.url);
            case 'set_clipboard_image':
                return await setClipboardImageFromBase64(cmd.data_base64, cmd.mime);
            case 'fetch_image':
                return await fetchImageData(cmd.url);
            case 'copy_text':
                await navigator.clipboard.writeText(cmd.text || '');
                return { ok: true };
            case 'pause_events':
                eventsPaused = true;
                return { ok: true };
            case 'resume_events':
                eventsPaused = false;
                return { ok: true };
            default:
                throw new Error('Unknown command: ' + cmd.action);
        }
    }

    async function pollCommands() {
        if (pollBusy) {
            if (pollBusySince && Date.now() - pollBusySince > 20000)
                pollBusy = false;
            else
                return;
        }
        pollBusy = true;
        pollBusySince = Date.now();
        try {
            for (let n = 0; n < 8; n++) {
                let commandId = '';
                try {
                    const resp = await http('GET', '/api/command?role=bot');
                    if (!resp.body || !resp.body.action) return;
                    commandId = resp.body.id || '';
                    await replyCommand(resp.body);
                } catch (err) {
                    if (!commandId) return;
                    try {
                        await http('POST', '/api/command-result', {
                            id: commandId,
                            ok: false,
                            error: String(err.message || err)
                        });
                    } catch (_) { /* ignore */ }
                }
            }
        } finally {
            pollBusy = false;
            pollBusySince = 0;
        }
    }

    async function pushLatestMessage() {
        if (eventsPaused) return;
        const group = getConversationTitle();
        if (isOutputGroup(group)) return;
        const messages = collectMessages();
        if (!messages.length) return;
        const latest = messages[messages.length - 1];
        const hash = latest.hash + '|' + group;
        if (hash === lastPushHash) return;
        lastPushHash = hash;

        await http('POST', '/api/event', {
            type: 'message',
            group,
            text: latest.text,
            images: latest.images,
            hasImage: latest.images.length > 0,
            hash: latest.hash,
            ts: Date.now()
        });
    }

    function schedulePush() {
        if (observerDebounce) clearTimeout(observerDebounce);
        observerDebounce = setTimeout(() => {
            pushLatestMessage().catch(() => {});
        }, 250);
    }

    function startObserver() {
        const root = getMessagePane();
        if (observer) observer.disconnect();
        observer = new MutationObserver(() => schedulePush());
        observer.observe(root, { childList: true, subtree: true });
    }

    let bootstrapped = false;

    async function bootstrap() {
        if (bootstrapped) {
            applyRoleTitle();
            showStatusBadge();
            await registerRole();
            return;
        }
        bootstrapped = true;
        BRIDGE.role = detectRole();
        applyRoleTitle();
        showStatusBadge();
        console.info('[ZaloBot] single-tab role=bot', location.href);

        await registerRole();
        if (pollTimer) clearInterval(pollTimer);
        pollTimer = setInterval(pollCommands, BRIDGE.pollMs);
        await refreshPublicConfig();
        if (registerTimer) clearInterval(registerTimer);
        registerTimer = setInterval(() => {
            applyRoleTitle();
            showStatusBadge();
            registerRole();
            refreshPublicConfig();
        }, 2000);

        startObserver();

        try {
            const health = await http('GET', '/api/health');
            if (health.body && health.body.ok) {
                console.info('[ZaloBot] AHK bridge connected', health.body);
            }
        } catch (_) {
            console.info('[ZaloBot] AHK bridge chưa sẵn sàng.');
        }
    }

    function startWhenReady() {
        bootstrap().catch(err => console.warn('[ZaloBot] bootstrap', err));
    }

    startWhenReady();
    document.addEventListener('DOMContentLoaded', startWhenReady);
    window.addEventListener('load', startWhenReady);
    window.addEventListener('pageshow', startWhenReady);
    window.addEventListener('focus', () => registerRole());
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden) registerRole();
    });
    if (window.onurlchange === null)
        window.addEventListener('urlchange', startWhenReady);
})();
