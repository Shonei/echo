// Chat functionality
import { Socket } from "phoenix";

// Wait for DOM to be ready
document.addEventListener("DOMContentLoaded", function () {
  // Check if we're on a chat room page
  if (!window.chatRoom || !window.chatUserId) {
    return;
  }

  const room = window.chatRoom;
  const userId = window.chatUserId;

  // Initialize socket connection
  let socket = new Socket("/socket", {
    params: { user_id: userId },
  });

  socket.connect();

  // Join the chat channel
  let channel = socket.channel(`chat:${room}`, {});

  // DOM elements
  const messagesContainer = document.getElementById("messages");
  const messageForm = document.getElementById("message-form");
  const messageInput = document.getElementById("message-input");
  const usernameInput = document.getElementById("username-input");
  const sendButton = document.getElementById("send-button");
  const statusIndicator = document.getElementById("status-indicator");

  // Update connection status
  function updateStatus(status, message) {
    if (statusIndicator) {
      statusIndicator.className = `inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium ${status}`;
      statusIndicator.textContent = message;
    }
  }

  // Format timestamp
  function formatTime(timestamp) {
    const date = new Date(timestamp);
    return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  // Escape HTML to prevent XSS
  function escapeHtml(text) {
    const div = document.createElement("div");
    div.textContent = text;
    return div.innerHTML;
  }

  // Add message to UI
  function addMessage(message) {
    if (!messagesContainer) return;

    const messageEl = document.createElement("div");
    messageEl.className = "flex items-start space-x-3";
    messageEl.innerHTML = `
      <div class="flex-shrink-0">
        <div class="w-8 h-8 bg-blue-500 rounded-full flex items-center justify-center text-white text-sm font-medium">
          ${escapeHtml(message.username.charAt(0).toUpperCase())}
        </div>
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center space-x-2">
          <p class="text-sm font-medium text-gray-900">${escapeHtml(
            message.username
          )}</p>
          <p class="text-xs text-gray-500">${formatTime(
            message.inserted_at
          )}</p>
        </div>
        <p class="text-sm text-gray-700 mt-1">${escapeHtml(message.content)}</p>
      </div>
    `;
    messagesContainer.appendChild(messageEl);

    // Scroll to bottom
    const container = document.getElementById("messages-container");
    if (container) {
      container.scrollTop = container.scrollHeight;
    }
  }

  // Set default username from user ID
  if (usernameInput) {
    const defaultUsername = userId.startsWith("user_")
      ? `Guest ${userId.split("_")[1]}`
      : userId;
    usernameInput.value = defaultUsername;

    // Save username to localStorage when changed
    usernameInput.addEventListener("change", () => {
      localStorage.setItem("chatUsername", usernameInput.value);
    });

    // Load saved username from localStorage
    const savedUsername = localStorage.getItem("chatUsername");
    if (savedUsername) {
      usernameInput.value = savedUsername;
    }
  }

  // Handle form submission
  if (messageForm) {
    messageForm.addEventListener("submit", (e) => {
      e.preventDefault();
      const content = messageInput.value.trim();
      const username = usernameInput ? usernameInput.value.trim() : "Anonymous";

      if (content) {
        if (!username) {
          alert("Please enter a username before sending messages.");
          usernameInput.focus();
          return;
        }

        sendButton.disabled = true;
        channel
          .push("new_message", { content: content, username: username })
          .receive("ok", (resp) => {
            messageInput.value = "";
            sendButton.disabled = false;
            messageInput.focus();
          })
          .receive("error", (resp) => {
            console.error("Error sending message:", resp);
            sendButton.disabled = false;
            alert("Error sending message. Please try again.");
          });
      }
    });
  }

  // Channel event handlers
  channel
    .join()
    .receive("ok", (resp) => {
      console.log("Joined successfully", resp);
      updateStatus("bg-green-100 text-green-800", "Connected");

      // Load existing messages
      if (resp.messages) {
        resp.messages.forEach(addMessage);
      }

      if (messageInput) {
        messageInput.focus();
      }
    })
    .receive("error", (resp) => {
      console.log("Unable to join", resp);
      updateStatus("bg-red-100 text-red-800", "Connection failed");
    });

  // Listen for new messages
  channel.on("new_message", (payload) => {
    addMessage(payload.message);
  });

  // Handle socket connection events
  socket.onOpen(() => {
    updateStatus("bg-green-100 text-green-800", "Connected");
  });

  socket.onError(() => {
    updateStatus("bg-red-100 text-red-800", "Connection error");
  });

  socket.onClose(() => {
    updateStatus("bg-yellow-100 text-yellow-800", "Disconnected");
  });
});
