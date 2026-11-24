// A user-supplied bootstrap whose `web_defines` value has to reach the page.
//
// Lives in `dev_boot/web/`, not the root's `web/`, on purpose: the root's
// `web/` feeds every Tier 1 target there, so a `web/flutter_bootstrap.js` in
// it would silently become the bootstrap of all of them. Only
// `:app_dev_boot`, whose pubspec is `dev_boot/pubspec.yaml`, reads this file.
//
// `rulesFlutterApiUrl` is what a `-d chrome` run is asserted on. It reaches the
// browser only if the dev loop serves this template, substituted — a dev loop
// that writes a bootstrap of its own leaves the global undefined while the
// built bundle carries the value, which is exactly the split this target
// exists to catch.
window.rulesFlutterApiUrl = "{{API_URL}}";

{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function () {
    _flutter.loader.load({
      serviceWorkerSettings: {
        serviceWorkerVersion: {{flutter_service_worker_version}}
      }
    });
  });
  document.head.appendChild(script);
}
