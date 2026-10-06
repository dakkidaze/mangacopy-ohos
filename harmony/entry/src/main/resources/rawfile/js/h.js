javascript:
if (typeof (loaded) == "undefined") {
    var loaded = true;
    function scanChapters(chapter) {
        var chapterList = chapter.getElementsByClassName("tab-pane fade show active")[0].getElementsByTagName("ul")[0].getElementsByTagName("a");
        var chapterArr = Array();
        for (var i = 0; i < chapterList.length; i++) {
            chapterArr.push({"name": chapterList[i].title, "url": chapterList[i].href});
        }
        return chapterArr;
    }
    function smoothLoadChapter() {
        var sourceProfile = window.__CM_SOURCE_PROFILE || "fast";
        var fixedSpeed = sourceProfile === "normal" ? 320 : 0;
        var MIN_SPEED = sourceProfile === "conservative" ? 160 : sourceProfile === "turbo" ? 300 : 200;
        var MAX_SPEED = sourceProfile === "conservative" ? 420 : sourceProfile === "turbo" ? 800 : 600;
        var SPEED_ADJUST_INTERVAL = sourceProfile === "conservative" ? 420 : 300;
        var currentSpeed = sourceProfile === "conservative" ? 260 : sourceProfile === "turbo" ? 500 : 350;
        var prevHeight = 0;
        var waitStartTime = 0;
        var prevUrlCount = 0;
        var bottomStuckRounds = 0;
        var hintStartTime = 0;
        var hintShown = false;
        var speedAdjustCooldown = 0;
        var lastTime = 0;
        var ticking = false;

        function toMobileUrl(pcUrl) {
            var m = pcUrl.match(/\/comic\/([^\/]+)\/chapter\/([^\/]+)/);
            if (!m) return pcUrl;
            return location.origin + "/comicContent/" + m[1] + "/" + m[2];
        }

        function allDataSrcReady(contentEl) {
            var items = contentEl.getElementsByTagName("li");
            if (items.length === 0) return false;
            for (var i = 0; i < items.length; i++) {
                var img = items[i].getElementsByTagName("img")[0];
                if (img && !img.dataset.src) return false;
            }
            return true;
        }

        function countUrls(contentEl) {
            var items = contentEl.getElementsByTagName("li");
            var count = 0;
            for (var i = 0; i < items.length; i++) {
                var img = items[i].getElementsByTagName("img")[0];
                if (img && img.dataset.src) count++;
            }
            return count;
        }

        function finish(contentEl) {
            var nextEl = document.getElementsByClassName("comicContent-next")[0];
            var prevEl = document.getElementsByClassName("comicContent-prev")[1];
            if (!contentEl || !nextEl || !prevEl) {
                if (typeof GM !== "undefined") GM.setLoadingDialog(false);
                return;
            }
            var nextA = nextEl.getElementsByTagName("a")[0];
            var prevA = prevEl.getElementsByTagName("a")[0];
            var nextChapter = nextA && nextA.href ? nextA.href : location.href;
            var prevChapter = prevA && prevA.href ? prevA.href : location.href;
            if (nextChapter == location.href) nextChapter = "null";
            if (prevChapter == location.href) prevChapter = "null";
            if (nextChapter !== "null") nextChapter = toMobileUrl(nextChapter);
            if (prevChapter !== "null") prevChapter = toMobileUrl(prevChapter);
            var result = document.title.split(" - ")[1] + " " + location.href.substring(location.href.lastIndexOf("/") + 1) + "\n" + nextChapter + "\n" + prevChapter;
            var images = contentEl.getElementsByTagName("li");
            for (var i = 0; i < images.length; i++) {
                var img = images[i].getElementsByTagName("img")[0];
                if (img && img.dataset.src) result += "\n" + img.dataset.src;
            }
            if (typeof GM !== "undefined") {
                GM.setLoadingDialog(false);
                GM.loadChapter(result);
            }
        }

        function requestTick() {
            if (!ticking) {
                ticking = true;
                requestAnimationFrame(step);
            }
        }

        function step(timestamp) {
            try {
                if (!lastTime) lastTime = timestamp;
                var elapsed = timestamp - lastTime;
                if (elapsed >= 16) {
                    var comicCountEls = document.getElementsByClassName("comicCount");
                    var count = comicCountEls.length > 0 ? comicCountEls[0].innerText : "999";
                    window.scrollBy(0, fixedSpeed > 0 ? fixedSpeed : currentSpeed);
                    lastTime = timestamp;
                    var currentHeight = document.body.scrollHeight;
                    var atBottom = Math.round(window.innerHeight + window.scrollY + 0.5) >= currentHeight;
                    var contentEl = document.getElementsByClassName("container-fluid comicContent")[0];
                    var items = contentEl ? contentEl.getElementsByTagName("li") : [];
                    var totalCount = parseInt(count);
                    var hasTotalCount = !isNaN(totalCount) && totalCount > 0 && count !== "999";
                    var loadedCount = contentEl ? countUrls(contentEl) : 0;
                    var previousLoadedCount = prevUrlCount;
                    if (typeof GM !== "undefined" && GM.setLoadingDialogProgress) {
                        GM.setLoadingDialogProgress(String(loadedCount), hasTotalCount ? count : String(items.length));
                    }

                    if (!hintShown) {
                        if (loadedCount === previousLoadedCount && loadedCount > 0 && loadedCount < (hasTotalCount ? totalCount : items.length)) {
                            if (hintStartTime === 0) hintStartTime = timestamp;
                            if (timestamp - hintStartTime >= 1000) {
                                if (typeof GM !== "undefined" && GM.setLoadingDialogProgress) {
                                    GM.setLoadingDialogProgress(
                                        String(loadedCount),
                                        (hasTotalCount ? count : String(items.length)) + "  网络较慢，可到设置里重测/切换源"
                                    );
                                }
                                hintShown = true;
                            }
                        } else {
                            hintStartTime = 0;
                        }
                    }

                    var isFullyLoaded = hasTotalCount && items.length > 0 && items.length >= totalCount && allDataSrcReady(contentEl);
                    if (fixedSpeed === 0 && contentEl && speedAdjustCooldown <= 0) {
                        var urlCount = countUrls(contentEl);
                        var urlDelta = urlCount - prevUrlCount;
                        if (urlDelta === 0 && hasTotalCount && items.length < totalCount) {
                            currentSpeed = Math.max(MIN_SPEED, currentSpeed - (sourceProfile === "conservative" ? 35 : sourceProfile === "turbo" ? 60 : 50));
                        } else if (urlDelta >= 3) {
                            currentSpeed = Math.min(MAX_SPEED, currentSpeed + (sourceProfile === "conservative" ? 20 : sourceProfile === "turbo" ? 40 : 30));
                        }
                        prevUrlCount = urlCount;
                        speedAdjustCooldown = SPEED_ADJUST_INTERVAL;
                    }
                    if (fixedSpeed === 0) speedAdjustCooldown--;

                    if (atBottom && currentHeight !== prevHeight) {
                        prevHeight = currentHeight;
                    }

                    if (atBottom && hasTotalCount && loadedCount < totalCount) {
                        if (loadedCount === previousLoadedCount) bottomStuckRounds++;
                        else bottomStuckRounds = 0;
                        var pullbackRound = sourceProfile === "conservative" ? 3 : 2;
                        var pushforwardRound = sourceProfile === "conservative" ? 4 : 3;
                        var activeSpeed = fixedSpeed > 0 ? fixedSpeed : currentSpeed;
                        if (bottomStuckRounds === pullbackRound) {
                            window.scrollBy(0, -Math.max(sourceProfile === "conservative" ? 180 : 240, Math.floor(activeSpeed * 0.8)));
                        } else if (bottomStuckRounds >= pushforwardRound) {
                            window.scrollBy(0, Math.max(sourceProfile === "conservative" ? 320 : 420, Math.floor(activeSpeed * 1.1)));
                            bottomStuckRounds = 0;
                        }
                    } else {
                        bottomStuckRounds = 0;
                    }

                    var shouldFinish = false;

                    if (isFullyLoaded) {
                        shouldFinish = true;
                    } else if (!hasTotalCount && atBottom && allDataSrcReady(contentEl)) {
                        if (waitStartTime === 0) waitStartTime = timestamp;
                        if (timestamp - waitStartTime >= 500) {
                            waitStartTime = 0;
                            shouldFinish = true;
                        } else {
                            requestTick();
                            return;
                        }
                    } else {
                        waitStartTime = 0;
                    }

                    if (shouldFinish) {
                        finish(contentEl);
                        return;
                    }
                }
                ticking = false;
                requestTick();
            } catch (e) {
                if (typeof GM !== "undefined") GM.setLoadingDialog(false);
            }
        }

        requestTick();
    }

    function modify() {
        var url = location.href;
        if(url.indexOf("/chapter/") > 0){
            if(typeof GM !== "undefined" && GM.setLoadingDialog) {
                GM.setLoadingDialog(true);
                smoothLoadChapter();
            }
        } else {
            var json = Array();
            var chapters = document.getElementsByClassName("upLoop")[0].children;
            var newObj = null;
            for(var i = 0; i < chapters.length; i++) {
                if(i % 2) {
                    newObj["chapters"] = scanChapters(chapters[i]);
                    json.push(newObj);
                    newObj = null;
                }
                else {
                    newObj = {"name": chapters[i].innerText};
                }
            }
            GM.setTitle(document.getElementsByTagName("h6")[0].title);
            GM.setFab(JSON.stringify(json));
        }
    }
    modify();
} else {
    setTimeout(modify, 100);
}