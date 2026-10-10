(function initializeClarity(window, document) {
  if (window.location.hostname !== "storage.daddyrad.com") return;

  const projectId = "ymdrqo4jyc";
  window.clarity = window.clarity || function clarity() {
    (window.clarity.q = window.clarity.q || []).push(arguments);
  };

  let done = false;
  const events = ["pointerdown", "keydown", "touchstart", "scroll"];
  function load() {
    if (done) return;
    done = true;
    events.forEach((event) => window.removeEventListener(event, load));
    window.clearTimeout(timer);
    const script = document.createElement("script");
    script.async = true;
    script.src = `https://www.clarity.ms/tag/${projectId}`;
    const firstScript = document.getElementsByTagName("script")[0];
    firstScript.parentNode.insertBefore(script, firstScript);
  }
  events.forEach((event) => window.addEventListener(event, load, { passive: true, once: true }));
  const timer = window.setTimeout(load, 90000);
  window.clarity("set", "project_id", "storagedaddy");
})(window, document);
