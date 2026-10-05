// Theme toggle, copy buttons on code blocks, the doc nav's current section, and the latest
// release's version on download buttons.

(() => {
  const root = document.documentElement;
  const stored = (() => {
    try { return localStorage.getItem("theme"); } catch { return null; }
  })();
  if (stored) root.dataset.theme = stored;

  document.addEventListener("DOMContentLoaded", () => {
    const toggle = document.querySelector(".theme-toggle");
    toggle?.addEventListener("click", () => {
      const dark = root.dataset.theme
        ? root.dataset.theme === "dark"
        : matchMedia("(prefers-color-scheme: dark)").matches;
      root.dataset.theme = dark ? "light" : "dark";
      try { localStorage.setItem("theme", root.dataset.theme); } catch {}
    });

    for (const pre of document.querySelectorAll("pre")) {
      const button = document.createElement("button");
      button.className = "copy-button";
      button.type = "button";
      button.textContent = "Copy";
      button.addEventListener("click", async () => {
        const text = pre.querySelector("code")?.innerText ?? pre.innerText;
        try {
          await navigator.clipboard.writeText(text.replace(/\n$/, ""));
          button.textContent = "Copied";
        } catch {
          button.textContent = "Select and copy";
        }
        setTimeout(() => (button.textContent = "Copy"), 1600);
      });
      pre.append(button);
    }

    const links = [...document.querySelectorAll(".doc-nav a[href^='#']")];
    const sections = links.map((link) => document.querySelector(link.getAttribute("href"))).filter(Boolean);
    if (sections.length) {
      const observer = new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          links.forEach((link) => link.classList.toggle("active", link.getAttribute("href") === `#${entry.target.id}`));
        }
      }, { rootMargin: "-90px 0px -70% 0px" });
      sections.forEach((section) => observer.observe(section));
    }

    const versions = document.querySelectorAll("[data-latest-version]");
    if (versions.length) {
      fetch("https://api.github.com/repos/justintout/GIFt/releases/latest")
        .then((response) => (response.ok ? response.json() : null))
        .then((release) => {
          if (!release?.tag_name) return;
          versions.forEach((element) => (element.textContent = `Version ${release.tag_name.replace(/^v/, "")}`));
        })
        .catch(() => {});
    }
  });
})();
