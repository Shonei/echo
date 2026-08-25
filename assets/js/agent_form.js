// Shows only the fields that belong to the selected provider on the "Create AI
// Agent" form. Every provider-specific block is marked `data-provider="<name>"`;
// this hides the ones that don't match and disables their inputs so the browser
// leaves them out of the submission entirely — otherwise a hidden Gemini model
// select would still post a value alongside an OpenRouter slug.
document.addEventListener("DOMContentLoaded", function () {
  const providerSelect = document.getElementById("agent_provider");
  const form = document.getElementById("agent-form");

  if (!providerSelect || !form) return;

  const panes = form.querySelectorAll("[data-provider]");

  function applyProvider() {
    const provider = providerSelect.value;

    panes.forEach(function (pane) {
      const matches = pane.dataset.provider === provider;

      pane.classList.toggle("hidden", !matches);

      // Disabled inputs are not submitted, which is exactly what we want: the
      // controller then sees only the fields for the provider in play.
      pane.querySelectorAll("input, select, textarea").forEach(function (field) {
        field.disabled = !matches;
      });
    });
  }

  providerSelect.addEventListener("change", applyProvider);
  applyProvider();
});
