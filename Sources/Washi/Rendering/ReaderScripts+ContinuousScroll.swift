import Foundation

extension ReaderScripts {
    // 各章は元の文書のまま iframe に保持する。ビューポート大の iframe を sticky に
    // 配置し、外側のスクロールに本文位置を追従させることで、章境界も同時に表示する。
    static let continuousScrollScript = #"""
    (function () {
        'use strict';
        window.__washiScrollContainer = true;
        const api = {};
        window.__washi = api;
        let items = [], active = null, options = {}, horizontal = false, negative = false;
        let width = 1, height = 1, total = 1, syncing = false, ready = false, generation = 0;
        let previousOffset = 0, preferred = null;
        let rollOnly = false;
        const element = name => document.createElementNS('http://www.w3.org/1999/xhtml', name);
        const viewport = () => horizontal ? width : height;
        const offset = () => horizontal ? (negative ? -window.scrollX : window.scrollX) : window.scrollY;
        const maximum = () => Math.max(0, total - viewport());
        const lastItem = item => item === items[items.length - 1];
        const span = item => Math.max(0, item.extent - (lastItem(item) ? viewport() : 0));
        const count = item => Math.max(1, Math.ceil(item.extent / viewport()));
        const local = item => Math.max(0, Math.min(span(item), offset() - item.start));
        const progression = item => span(item) > 0 ? local(item) / span(item) : 0;
        const page = item => Math.min(count(item) - 1, Math.max(0, lastItem(item)
            ? Math.round(progression(item) * (count(item) - 1))
            : Math.floor(progression(item) * count(item))));
        function post(message) {
            message.token = options.documentToken || '';
            try { window.webkit.messageHandlers.washi.postMessage(message); } catch (_) {}
        }
        function report() {
            if (!ready || !active) { return; }
            post({ type: 'pageChanged', spineIndex: active.index, page: page(active),
                   pageCount: count(active), pagesPerScreen: 1, mode: active.mode,
                   progression: progression(active), printPageMarkers: active.markers });
        }
        function transformRect(item, rect) {
            const bounds = item.frame.getBoundingClientRect();
            return { x: bounds.left + rect.x * item.scale, y: bounds.top + rect.y * item.scale,
                     w: rect.w * item.scale, h: rect.h * item.scale };
        }
        function sync(shouldReport = true) {
            if (!ready || syncing) { return; }
            syncing = true;
            const position = offset();
            active = preferred || items.find(item => position < item.start + item.extent - 0.5)
                || items[items.length - 1];
            for (const item of items) {
                if (item.roll || item.start > position + viewport()
                    || item.start + item.extent < position) { continue; }
                const internalMaximum = Math.max(0, item.extent - viewport());
                item.original.showProgression(internalMaximum > 0
                    ? Math.max(0, Math.min(1, (position - item.start) / internalMaximum)) : 0);
                item.syncedOffset = item.child.scrollMetrics().offset;
            }
            previousOffset = position;
            syncing = false;
            if (shouldReport) { report(); }
            if (rollOnly) { refreshRollFrames(); }
        }
        function scrollTo(value, item = null) {
            preferred = item;
            const position = Math.max(0, Math.min(maximum(), Number(value) || 0));
            window.scrollTo({ left: horizontal ? (negative ? -position : position) : 0,
                              top: horizontal ? 0 : position, behavior: 'instant' });
            sync();
            return active ? page(active) : 0;
        }
        function select(item, fraction) {
            return scrollTo(item.start + Math.max(0, Math.min(1, Number(fraction) || 0)) * span(item), item);
        }
        function route(item, message) {
            if (!ready || syncing || !items.includes(item)) { return; }
            if (message.type === 'pageChanged') {
                // Tab/VoiceOver など、内側の文書が発行した移動も外側へ反映する。
                const metrics = item.child.scrollMetrics();
                if (Math.abs(metrics.offset - (item.syncedOffset || 0)) < 0.5) { return; }
                if (!item.roll) { scrollTo(item.start + metrics.offset, item); }
                return;
            }
            if (message.type === 'boundary') { api.turnInDoc(message.forward); return; }
            if (message.type === 'selection' && !message.text) {
                if (active === item) { post(message); }
                return;
            }
            active = item;
            preferred = item;
            report();
            message.spineIndex = item.index;
            if (message.rects) { message.rects = message.rects.map(rect => transformRect(item, rect)); }
            if (message.anchorRect) { message.anchorRect = transformRect(item, message.anchorRect); }
            if (message.type === 'tap') {
                const bounds = item.frame.getBoundingClientRect();
                message.x = (bounds.left + message.x * bounds.width) / width;
                message.y = (bounds.top + message.y * bounds.height) / height;
            }
            post(message);
        }
        function makeWrapper(item) {
            const wrapper = element('div');
            wrapper.style.cssText = 'flex:none;position:relative;overflow:clip;';
            item.wrapper = wrapper;
            document.body.appendChild(wrapper);
            return wrapper;
        }
        async function load(item, epoch) {
            if (!item.renderable) { throw new Error(`No renderable fallback for chapter: ${item.index}`); }
            const wrapper = item.wrapper || makeWrapper(item);
            const frame = element('iframe');
            item.frame = frame; item.scale = item.roll ? width / item.width : 1;
            frame.style.cssText = 'display:block;border:0;position:sticky;top:0;left:0;right:0;';
            frame.title = `EPUB ${item.index + 1}`;
            frame.style.width = `${item.roll ? item.width : width}px`;
            frame.style.height = `${item.roll ? item.height : height}px`;
            if (item.roll) {
                frame.style.position = 'absolute';
                frame.style.transformOrigin = 'top left';
                frame.style.transform = `scale(${item.scale})`;
            }
            wrapper.appendChild(frame);
            await new Promise((resolve, reject) => {
                const timer = setTimeout(() => reject(new Error(`Chapter load timed out: ${item.index}`)), 15000);
                frame.onload = () => { clearTimeout(timer); resolve(); };
                frame.onerror = () => { clearTimeout(timer); reject(new Error(`Chapter load failed: ${item.index}`)); };
                frame.src = item.url;
            });
            if (epoch !== generation) { throw new Error('Scroll setup superseded'); }
            const child = frame.contentWindow.__washi;
            if (!child || !frame.contentDocument.documentElement
                || frame.contentDocument.querySelector('parsererror')) {
                throw new Error(`Cannot prepare chapter: ${item.index}`);
            }
            item.child = child;
            item.original = { showPage: child.showPage, showProgression: child.showProgression };
            child.hostPost = message => route(item, message);
            child.scrollHostWheel = event => {
                const unit = event.deltaMode === 1 ? 20 : event.deltaMode === 2 ? viewport() : 1;
                const delta = horizontal && Math.abs(event.deltaX) > Math.abs(event.deltaY)
                    ? event.deltaX * (negative ? -1 : 1) : event.deltaY;
                scrollTo(offset() + delta * unit);
            };
            const result = child.setup({ ...options, flow: 'scrolled-doc', fixedLayout: item.roll,
                width: item.roll ? item.width : width, height: item.roll ? item.height : height,
                spread: false });
            item.mode = item.roll ? 'htb' : result.mode;
            item.markers = result.printPageMarkers || [];
            item.extent = item.roll ? item.height * width / item.width : child.scrollMetrics().extent;
            // 範囲・フラグメント・音声同期が呼ぶ章内移動も外側へ転送する。
            child.showPage = n => {
                const internalMaximum = Math.max(0, item.extent - viewport());
                const internalCount = Math.max(1, result.pageCount);
                const position = internalCount <= 1 ? 0 : Math.max(0, Math.min(internalCount - 1, n))
                    / (internalCount - 1) * internalMaximum;
                scrollTo(item.start + position, item);
                return page(item);
            };
            child.turnInDoc = forward => api.turnInDoc(forward);
            if (item.highlights) { child.setHighlights(item.highlights); }
        }
        function ensureLoaded(item) {
            if (item.child) { return Promise.resolve(); }
            if (item.loading) { return item.loading; }
            const epoch = generation;
            item.loading = load(item, epoch).then(() => {
                item.loading = null;
                if (epoch === generation && ready) { sync(); }
            }, error => {
                item.loading = null;
                item.failed = true;
                if (epoch === generation) { post({ type:'scrollFailure', reason:String(error) }); }
                throw error;
            });
            return item.loading;
        }
        function refreshRollFrames() {
            const position = offset();
            for (const item of items) {
                if (item.start <= position + 2 * viewport()
                    && item.start + item.extent >= position - viewport()) {
                    if (!item.failed) { ensureLoaded(item).catch(() => {}); }
                } else if (!item.loading && item.frame) {
                    item.frame.remove();
                    item.frame = null;
                    item.child = null;
                    item.original = null;
                }
            }
        }
        api.setup = async function (next) {
            const epoch = ++generation;
            ready = false;
            options = next;
            width = Math.max(1, Math.floor(Number(next.width) || 1));
            height = Math.max(1, Math.floor(Number(next.height) || 1));
            items = (next.continuousItems || []).map(item => ({ ...item }));
            if (!items.length) { throw new Error('Empty continuous reading order'); }
            document.body.replaceChildren();
            const style = element('style');
            style.textContent = `html { margin:0!important;padding:0!important;overflow:auto!important;
                scrollbar-width:none!important;scroll-behavior:auto!important; }
                body { margin:0!important;padding:0!important; }
                html::-webkit-scrollbar { display:none!important; }`;
            document.head.replaceChildren(style);
            document.documentElement.style.direction = 'ltr';
            document.body.style.cssText = '';
            rollOnly = items.every(item => item.roll);
            if (rollOnly) {
                // roll の長さは宣言寸法で決まる。遠い章は枠だけにし、画像や DOM を保持しない。
                for (const item of items) {
                    makeWrapper(item);
                    item.mode = 'htb'; item.markers = []; item.scale = width / item.width;
                    item.extent = item.height * item.scale;
                }
            } else {
                // 同時読み込みを抑えつつ、spine の DOM 順は入れ替えない。
                for (let start = 0; start < items.length; start += 4) {
                    await Promise.all(items.slice(start, start + 4).map(item => load(item, epoch)));
                }
            }
            if (epoch !== generation) { throw new Error('Scroll setup superseded'); }
            horizontal = items[0].mode !== 'htb';
            negative = items[0].mode === 'vrl';
            if (items.some(item => (item.mode !== 'htb') !== horizontal
                || (horizontal && (item.mode === 'vrl') !== negative))) {
                throw new Error('Continuous chapters use incompatible block flow directions');
            }
            document.documentElement.style.direction = negative ? 'rtl' : 'ltr';
            document.body.style.cssText = horizontal
                ? `display:flex;flex-direction:row;width:max-content;height:${height}px;direction:${negative ? 'rtl' : 'ltr'};`
                : `display:flex;flex-direction:column;width:${width}px;`;
            total = 0;
            for (const item of items) {
                item.start = total;
                total += item.extent;
                item.wrapper.style.width = `${horizontal ? item.extent : width}px`;
                item.wrapper.style.height = `${horizontal ? height : item.extent}px`;
                if (item.roll && item.frame) {
                    item.scale = width / item.width;
                    item.frame.style.position = 'absolute';
                    item.frame.style.transformOrigin = 'top left';
                    item.frame.style.transform = `scale(${item.scale})`;
                }
            }
            active = items.find(item => item.index === next.spineIndex) || items[0];
            if (rollOnly) {
                const position = Math.min(maximum(), active.start);
                await Promise.all(items.filter(item => item.start <= position + 2 * viewport()
                    && item.start + item.extent >= position - viewport()).map(ensureLoaded));
                if (epoch !== generation) { throw new Error('Scroll setup superseded'); }
            }
            ready = true;
            select(active, 0);
            return { pageCount: count(active), pagesPerScreen: 1, imagePage: false,
                     mode: active.mode, printPageMarkers: active.markers,
                     firstPageOnRight: false, supportsColumnAxis: true };
        };
        api.repaginate = async function (next) {
            const index = active && active.index;
            const fraction = active ? progression(active) : 0;
            const result = await api.setup({ ...next, spineIndex: index });
            select(active, fraction);
            return result;
        };
        api.showPage = n => active ? select(active, Math.max(0, Math.min(count(active) - 1, n))
            / Math.max(1, count(active) - (lastItem(active) ? 1 : 0))) : 0;
        api.showLastPage = () => api.showPage(active ? count(active) - 1 : 0);
        api.showProgression = p => active ? select(active, p) : 0;
        api.currentProgression = () => active ? progression(active) : 0;
        api.turnInDoc = function (forward) {
            if (!ready) { return 'ignored'; }
            if (forward ? offset() >= maximum() - 1 : offset() <= 1) {
                post({ type: 'boundary', forward: !!forward });
                return 'boundary';
            }
            scrollTo(offset() + (forward ? 1 : -1) * viewport());
            return 'turned';
        };
        api.activeDocument = () => active && active.frame ? active.frame.contentDocument : document;
        api.scrollMetrics = () => ({ ready: ready, scrolled: true, continuous: true,
            mode: active ? active.mode : 'htb', extent: total, viewport: viewport(), offset: offset(),
            items: items.map(item => ({ index: item.index, start: item.start, extent: item.extent,
                pageCount: count(item), loaded: !!item.child, rect: item.frame
                    ? transformRect(item, { x:0, y:0, w:item.frame.contentWindow.innerWidth,
                        h:item.frame.contentWindow.innerHeight })
                    : { x:item.wrapper.getBoundingClientRect().x, y:item.wrapper.getBoundingClientRect().y,
                        w:item.wrapper.getBoundingClientRect().width, h:item.wrapper.getBoundingClientRect().height } })) });
        for (const name of ['clearSelection', 'buildTextMap']) {
            api[name] = async (...args) => {
                if (!active) { return null; }
                const item = active;
                await ensureLoaded(item);
                return item.child[name](...args);
            };
        }
        api.setHighlights = function (list) {
            if (!active) { return 0; }
            active.highlights = list;
            return active.child ? active.child.setHighlights(list) : 0;
        };
        api.showFragment = async function (id) {
            if (!active) { return 0; }
            const item = active;
            await ensureLoaded(item);
            if (!item.roll) { return item.child.showFragment(id); }
            const target = item.frame.contentDocument.getElementById(id)
                || Array.from(item.frame.contentDocument.getElementsByName(id))[0];
            const rect = target && (target.getClientRects()[0] || target.getBoundingClientRect());
            return scrollTo(item.start + (rect ? rect.y * item.scale : 0), item);
        };
        api.mediaOverlayHighlight = async function (id, cls) {
            if (!active) { return 0; }
            const item = active;
            await ensureLoaded(item);
            const result = item.child.mediaOverlayHighlight(id, cls);
            if (item.roll && id && !api.firstVisibleIdentifier([id])) { await api.showFragment(id); }
            return result;
        };
        api.visibleTextOffset = async function () {
            if (!active) { return -1; }
            const item = active;
            await ensureLoaded(item);
            const rect = item.frame.getBoundingClientRect();
            const clipX = negative ? Math.max(0, rect.right - width) : Math.max(0, -rect.left);
            return item.child.visibleTextOffset(clipX / item.scale, Math.max(0, -rect.top) / item.scale);
        };
        api.firstVisibleIdentifier = function (candidates) {
            if (!active || !active.frame) { return null; }
            for (const id of candidates) {
                const target = active.frame.contentDocument.getElementById(id);
                if (!target) { continue; }
                const raw = target.getClientRects()[0];
                if (!raw) { continue; }
                const rect = transformRect(active, { x:raw.x, y:raw.y, w:raw.width, h:raw.height });
                if (rect.x + rect.w > 0 && rect.x < width && rect.y + rect.h > 0 && rect.y < height) { return id; }
            }
            return null;
        };
        api.rectsForTextRange = async (...args) => {
            if (!active) { return []; }
            const item = active;
            await ensureLoaded(item);
            return item.child.rectsForTextRange(...args).map(rect => transformRect(item, rect));
        };
        api.locateAndShow = async function (...args) {
            if (!active) { return { found: false }; }
            const item = active;
            await ensureLoaded(item);
            const result = item.child.locateAndShow(...args);
            if (result.found) {
                if (item.roll && result.rects.length) {
                    scrollTo(item.start + result.rects[0].y * item.scale, item);
                }
                result.page = page(item);
                result.rects = result.rects.map(rect => transformRect(item, rect));
            }
            return result;
        };
        for (const name of ['setUserCSS', 'setKeysEnabled', 'setTapDeferral']) {
            api[name] = (...args) => {
                if (name === 'setUserCSS') { options.userCSS = args[0]; }
                if (name === 'setKeysEnabled') { options.keysEnabled = args[0]; }
                if (name === 'setTapDeferral') { options.deferTaps = args[0]; options.doubleClickDelayMS = args[1]; }
                for (const item of items) { if (item.child && item.child[name]) { item.child[name](...args); } }
                return true;
            };
        }
        api.printPageMarkers = () => active ? active.markers : [];
        window.addEventListener('scroll', function () {
            if (Math.abs(offset() - previousOffset) > 0.5) { preferred = null; }
            sync();
        }, { passive: true });
    })();
    """#
}
