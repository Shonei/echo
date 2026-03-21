document.addEventListener("DOMContentLoaded", function () {
  const chatForm = document.getElementById("agent-chat-form");
  const chatInput = document.getElementById("chat-input");
  const sendButton = document.getElementById("send-button");
  const sessionIdEl = document.getElementById("session-id");
  const messagesContainer = document.getElementById("messages-container");
  const loadingIndicator = document.getElementById("loading-indicator");

  if (!chatForm || !sessionIdEl) return;

  const sessionId = sessionIdEl.textContent.trim();

  // Escape HTML to prevent XSS
  function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }

  // Format the current time
  function getCurrentTime() {
    const now = new Date();
    return now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  }

  // Determine icon and color based on role
  function getRoleHtml(role) {
    let iconSvg = '';
    let textColor = '';
    
    if (role === 'user') {
      textColor = 'text-blue-500';
      iconSvg = '<svg class="w-5 h-5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 9a3 3 0 100-6 3 3 0 000 6zm-7 9a7 7 0 1114 0H3z" clip-rule="evenodd" /></svg>';
    } else if (role === 'model') {
      textColor = 'text-purple-500';
      iconSvg = '<svg class="w-5 h-5" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M10 2a2 2 0 00-2 2v1.5a.5.5 0 01-.5.5H6a2 2 0 00-2 2v6a2 2 0 002 2h8a2 2 0 002-2v-6a2 2 0 00-2-2h-1.5a.5.5 0 01-.5-.5V4a2 2 0 00-2-2h-2z" clip-rule="evenodd" /></svg>';
    }
    
    return `<div class="${textColor}">${iconSvg}</div><span class="font-semibold text-gray-700 capitalize">${role}</span>`;
  }

  // Determine wrapper classes based on role
  function getClassesForRole(role) {
    if (role === 'user') return "p-6 rounded-xl shadow-sm border bg-blue-50 border-blue-100 ml-8";
    if (role === 'model') return "p-6 rounded-xl shadow-sm border bg-white border-gray-200 mr-8";
    return "p-6 rounded-xl shadow-sm border bg-yellow-50 border-yellow-100";
  }

  function appendMessage(role, type, contentHtml) {
    const messageEl = document.createElement("div");
    messageEl.className = getClassesForRole(role);
    
    messageEl.innerHTML = `
      <div class="flex items-center justify-between mb-3 border-b border-gray-100 pb-2">
        <div class="flex items-center space-x-2">
          ${getRoleHtml(role)}
          <span class="text-xs text-gray-400 ml-2">${escapeHtml(type)}</span>
        </div>
        <div class="text-xs text-gray-400">
          ${getCurrentTime()}
        </div>
      </div>
      <div class="prose prose-sm max-w-none text-gray-800">
        ${contentHtml}
      </div>
    `;
    
    messagesContainer.appendChild(messageEl);
    scrollToBottom();
  }

  function appendTextPart(role, text, html) {
    const contentHtml = html ? `<div>${html}</div>` : `<div class="whitespace-pre-wrap font-sans">${escapeHtml(text)}</div>`;
    appendMessage(role, 'text', contentHtml);
  }
  
  function appendDocumentPart(role, inlineData) {
    let contentHtml = '';
    if (inlineData.mimeType && inlineData.mimeType.startsWith("image/")) {
      contentHtml = `<img src="data:${escapeHtml(inlineData.mimeType)};base64,${escapeHtml(inlineData.data)}" class="max-w-full rounded-md border border-gray-200" />`;
    } else {
      contentHtml = `<pre class="overflow-x-auto">${escapeHtml(JSON.stringify(inlineData, null, 2))}</pre>`;
    }
    appendMessage(role, 'document', contentHtml);
  }

  function scrollToBottom() {
    messagesContainer.scrollTop = messagesContainer.scrollHeight;
  }

  // Auto-scroll on load
  scrollToBottom();

  chatForm.addEventListener("submit", async function (e) {
    e.preventDefault();
    
    const text = chatInput.value.trim();
    if (!text) return;

    // Append user message immediately
    appendTextPart("user", text);
    chatInput.value = "";
    
    // Disable form and show loading
    sendButton.disabled = true;
    chatInput.disabled = true;
    loadingIndicator.classList.remove("hidden");

    try {
      const response = await fetch(`/api/agent-chat/${sessionId}/content`, {
        method: "PUT",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json"
        },
        body: JSON.stringify({ content_blocks: [{ text: text }] })
      });

      if (!response.ok) {
        throw new Error("Failed to send message: " + response.statusText);
      }

      const data = await response.json();
      
      // Look for text parts or image parts
      if (data.parts && Array.isArray(data.parts)) {
        data.parts.forEach(part => {
          if (part.text) {
            appendTextPart("model", part.text, part.html);
          } else if (part.inlineData) {
            appendDocumentPart("model", part.inlineData);
          } else {
             // Handle raw JSON display for other types (function calls, etc)
             const contentHtml = `<pre class="overflow-x-auto">${escapeHtml(JSON.stringify(part, null, 2))}</pre>`;
             appendMessage("model", Object.keys(part)[0] || "unknown", contentHtml);
          }
        });
      }

    } catch (error) {
      console.error(error);
      const errorHtml = `<div class="text-red-500">Error: ${escapeHtml(error.message)}</div>`;
      appendMessage("system", "error", errorHtml);
    } finally {
      // Re-enable form
      sendButton.disabled = false;
      chatInput.disabled = false;
      loadingIndicator.classList.add("hidden");
      chatInput.focus();
    }
  });

  // Allow enter to submit (shift+enter for new line)
  chatInput.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      chatForm.dispatchEvent(new Event("submit", { cancelable: true }));
    }
  });
});
