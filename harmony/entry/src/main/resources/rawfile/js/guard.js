// H5 阅读器守卫：不依赖 URL，依据页面内容与章节图片特征识别阅读视图。
(function () {
    function hasReaderImage() {
        return !!document.querySelector('img[src*="c1500x"], img[data-src*="c1500x"]');
    }

    function hasReaderText() {
        var body = document.body;
        if (!body) return false;
        var text = body.innerText || body.textContent || '';
        if (text.indexOf('漫畫觀看') >= 0 || text.indexOf('漫画观看') >= 0) return true;
        var hasPrevious = text.indexOf('上一話') >= 0 || text.indexOf('上一话') >= 0;
        var hasNext = text.indexOf('下一話') >= 0 || text.indexOf('下一话') >= 0;
        return hasPrevious && hasNext;
    }

    function isReaderView() {
        return hasReaderImage() || hasReaderText();
    }

    function checkReader() {
        var now = Date.now();
        if (window.__cmGuardQuietUntil && now < window.__cmGuardQuietUntil) return;
        if (!isReaderView()) {
            window.__cmGuardFired = false;
            return;
        }
        if (window.__cmGuardFired) return;
        window.__cmGuardFired = true;
        window.__cmGuardQuietUntil = now + 3000;
        try {
            if (window.GM && typeof window.GM.onReaderDetected === 'function') {
                window.GM.onReaderDetected();
            }
        } catch (_) {}
    }

    window.__cmReaderGuardCheck = checkReader;
    if (!window.__cmReaderGuardInstalled) {
        window.__cmReaderGuardInstalled = true;
        window.__cmGuardFired = false;
        window.__cmGuardQuietUntil = 0;
        var start = function () {
            checkReader();
            var root = document.documentElement || document.body;
            if (root) {
                new MutationObserver(checkReader).observe(root, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['src', 'data-src', 'class']
                });
            }
            setInterval(checkReader, 800);
        };
        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
            start();
        }
    } else {
        checkReader();
    }
})();
