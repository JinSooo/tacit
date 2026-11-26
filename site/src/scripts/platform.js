document.documentElement.classList.add("has-js");
(() => {
  const p = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
  const ua = navigator.userAgent || "";
  let os = "other";
  if (/android/i.test(ua) || /android/i.test(p)) os = "android";
  else if (/iphone|ipad|ipod/i.test(ua) || (/mac/i.test(p) && navigator.maxTouchPoints > 1)) os = "ios";
  else if (/win/i.test(p) || /windows/i.test(ua)) os = "windows";
  else if (/mac/i.test(p) || /macintosh|mac os/i.test(ua)) os = "mac";
  document.documentElement.setAttribute("data-platform", os);
})();
