javascript:
if (typeof (loaded) == "undefined") {
    var loaded = true;
    var invoke = {
        preUrl: "",
        lastBrowseUrl: "",
        _backFix: false,
        hideRanobeTab: function () {
            var tabs = document.getElementsByClassName("van-tabbar-item");
            for (i = 0; i < tabs.length; i++) {
                if (tabs[i].innerText == "輕小說") tabs[i].style = "display: none;";
            }
        },
        hideRanobeRack: function () {
            var tabs = document.getElementsByClassName("van-tabs van-tabs--line");
            if (tabs.length) tabs[0].hidden = true;
        },
        pinTitle: function () {
            var game = document.getElementsByName("exchange");
            if (game.length) game[0].hidden = true;
        },
        notCallGM: function (url) {
            if (this.preUrl == url) return false;
            else {
                this.preUrl = url;
                return true;
            }
        },
        clickClass: function (name, index) { document.getElementsByClassName(name)[index].click(); },
        clickClassCenter: function (name, index) {
            var elems = document.getElementsByClassName(name);
            if(elems.length > index) {
                var ev = document.createEvent('HTMLEvents');
                ev.clientX = innerWidth / 2;
                ev.clientY = innerHeight / 2;
                ev.initEvent('click', false, true);
                elems[index].dispatchEvent(ev);
            }
        },
        resetPreUrl: function () { this.preUrl = ""; },
        loadChapter: function () { this.clickClassCenter("comicContentPopupImageItem", 0); GM.loadComic(location.href); },
        rememberBrowse: function (url) {
            // 记录「非详情/非章节」的浏览位，供详情页返回时回落
            if (url.indexOf("/details/comic/") < 0 && url.indexOf("/comicContent/") < 0) {
                this.lastBrowseUrl = url;
            }
        },
        installChapterTap: function () {
            // 拦截章节点击：阻止 H5 跳进网页阅读器，直接交给原生阅读器。
            if (this._chapterTap) return;
            this._chapterTap = true;
            document.addEventListener("click", function (e) {
                try {
                    var t = e.target;
                    if (!t || !t.closest) return;
                    var a = t.closest('a[href]');
                    var href = a ? a.getAttribute('href') : '';
                    if (!href || href.indexOf('/comicContent/') < 0) return;
                    e.preventDefault();
                    e.stopImmediatePropagation();
                    GM.loadComic(new URL(href, location.origin).toString());
                } catch (_) {}
            }, true);
        },
        installBackFix: function () {
            // 站点顶栏返回在 history.state 异常时会 replace 到首页；
            // 详情/章节页捕获后改为 history.back，失败再回落上次浏览 URL。
            if (this._backFix) return;
            this._backFix = true;
            document.addEventListener("click", function (e) {
                var href = location.href;
                var onDetails = href.indexOf("/details/comic/") >= 0;
                var onChapter = href.indexOf("/comicContent/") >= 0;
                if (!onDetails && !onChapter) return;
                var t = e.target;
                if (!t || !t.closest) return;
                if (!t.closest(".van-nav-bar__left")) return;
                e.preventDefault();
                e.stopImmediatePropagation();
                var from = href;
                if (window.history.length > 1) {
                    history.back();
                    // SPA 若实际没动（或又被站点打回详情/章节），回落到浏览位
                    setTimeout(function () {
                        if (location.href !== from) return;
                        if (invoke.lastBrowseUrl) location.href = invoke.lastBrowseUrl;
                    }, 280);
                    return;
                }
                if (invoke.lastBrowseUrl) location.href = invoke.lastBrowseUrl;
            }, true);
        },
        injectAppSettings: function () {
            if (document.getElementById('_app_cfg')) return;
            var cell = document.createElement('div');
            cell.id = '_app_cfg';
            cell.style.cssText = 'display:flex;align-items:center;min-height:44px;padding:10px 16px;background:#fff;border-bottom:1px solid #ebedf0;cursor:pointer;';
            cell.innerHTML = '<span style="flex:1;font-size:14px;color:#323233;">&#9881; App扩展设置</span><span style="color:#969799;font-size:18px;">&#8250;</span>';
            cell.onclick = function () { GM.openSettings(); };
            var target = document.querySelector('.van-cell-group') ||
                document.querySelector('.van-list') ||
                document.querySelector('main') ||
                document.body;
            target.insertAdjacentElement('afterbegin', cell);
        },
        urlChangeListener: function (todo) {
            setInterval(function () { if (invoke.notCallGM(location.href)) { todo(); } }, 1000);
        }
    };
    function modify() {
        var url = location.href;
        invoke.rememberBrowse(url);
        invoke.installBackFix();
        invoke.installChapterTap();
        GM.hideFab();
        if (url.endsWith("/index")) {
            invoke.pinTitle();
        }
        else if (url.indexOf("/comicContent/") > 0) {
            setTimeout(function () { invoke.loadChapter() }, 1000);
        }
        else if (url.indexOf("/details/comic/") > 0) {
            GM.loadComic(url);
        }
        else if (url.indexOf("/personal") > 0) {
            GM.enterProfile();
            setTimeout(function () { invoke.injectAppSettings(); }, 1200);
        }
    }
    modify();
    invoke.urlChangeListener(modify);
} else {
    setTimeout(modify, 1280);
}
