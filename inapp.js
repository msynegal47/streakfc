// "Open in Safari/Chrome" nudge. In-app browsers (Instagram, Facebook, TikTok, Snapchat, Google app, Android webviews) keep their own storage,
// so StreakFC forgets players and coaches there. One tap gets them to the real browser where login sticks.
(function () {
  var ua = navigator.userAgent || '', m = ua.match(/(Instagram|FBAN|FBAV|Snapchat|musical_ly|Bytedance|LinkedInApp|Twitter|Line\/|GSA\/)/), wv = /; wv\)/.test(ua);
  if (!m && !wv) return;
  try { if (sessionStorage.getItem('sfc_inapp_x')) return; } catch (e) {}
  var app = ({Instagram:'Instagram', FBAN:'Facebook', FBAV:'Facebook', Snapchat:'Snapchat', musical_ly:'TikTok', Bytedance:'TikTok', LinkedInApp:'LinkedIn', Twitter:'X', 'Line/':'LINE', 'GSA/':'Google app'})[m ? m[1] : ''] || 'this app';
  var ios = /iPhone|iPad|iPod/.test(ua), url = location.href;
  var b = document.createElement('div');
  b.style.cssText = 'position:fixed;left:10px;right:10px;top:10px;z-index:99999;background:#111827;color:#fff;border:2px solid #f97316;border-radius:14px;padding:12px 14px;font:600 14px/1.35 system-ui,sans-serif;box-shadow:0 10px 30px #000a';
  var open = ios ? '<b>Tap ••• or the compass, then "Open in Safari"</b>' :
    '<a href="intent://' + location.host + location.pathname + location.search + location.hash + '#Intent;scheme=https;package=com.android.chrome;end" style="display:inline-block;margin-top:6px;background:#f97316;color:#000;border-radius:10px;padding:8px 12px;text-decoration:none;font-weight:800">Open in Chrome</a>';
  b.innerHTML = 'You opened StreakFC inside ' + app + ', so it won\'t remember you here.<br>' + open +
    '<div style="margin-top:8px;display:flex;gap:8px"><button id="iaCopy" style="background:#1f2937;color:#fff;border:1px solid #374151;border-radius:8px;padding:6px 10px;font:inherit">Copy link</button><button id="iaX" style="background:none;color:#9ca3af;border:0;font:inherit;margin-left:auto">Not now</button></div>';
  function add() { document.body.appendChild(b);
    document.getElementById('iaX').onclick = function () { try { sessionStorage.setItem('sfc_inapp_x', '1'); } catch (e) {} b.remove(); };
    document.getElementById('iaCopy').onclick = function () { try { navigator.clipboard.writeText(url); this.textContent = 'Copied. Paste in Safari/Chrome'; } catch (e) { this.textContent = url; } }; }
  if (document.body) add(); else document.addEventListener('DOMContentLoaded', add);
})();
