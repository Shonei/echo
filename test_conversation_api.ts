const API_BASE = "http://localhost:4000/api/v1";

async function runTest() {
    console.log("🚀 Starting Conversation API Test...\n");

    const username = "admin"
    const password = "password"

    console.log(`➡️  No TOKEN provided. Logging in as ${username}...`);

    const loginRes = await fetch(`${API_BASE}/login`, {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
        },
        body: JSON.stringify({
            username,
            password
        })
    });

    if (!loginRes.ok) {
        const errorBody = await loginRes.text();
        console.error(`❌ Login failed: ${loginRes.status} ${loginRes.statusText}`);
        console.error(errorBody);
        process.exit(1);
    }

    const loginData = await loginRes.json();
    const token = loginData.accessToken;
    console.log("✅ Login successful, token obtained.\n");


    const headers = {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`
    };

    // 1. Create a conversation with tools
    console.log("➡️  Creating conversation...");

    const tools = [
        {
            functionDeclarations: [
                {
                    name: "get_current_weather",
                    description: "Get the current weather in a given location",
                    parameters: {
                        type: "OBJECT",
                        properties: {
                            location: {
                                type: "STRING",
                                description: "The city and state, e.g. San Francisco, CA"
                            }
                        },
                        required: ["location"]
                    }
                }
            ]
        }
    ];

    const createRes = await fetch(`${API_BASE}/ai/conversation`, {
        method: "POST",
        headers,
        body: JSON.stringify({
            system_prompt: "You are a helpful assistant. Use tools if necessary.",
            temperature: 0.2,
            tools: tools
        })
    });

    if (!createRes.ok) {
        const errorBody = await createRes.text();
        console.error(`❌ Failed to create conversation: ${createRes.status} ${createRes.statusText}`);
        console.error(errorBody);
        process.exit(1);
    }

    const { id: conversationId } = await createRes.json();
    console.log(`✅ Conversation created with ID: ${conversationId}\n`);

    // 2. Send a message that triggers a tool call
    console.log("➡️  Sending message: 'What is the weather in Paris, France?'");
    const messageRes = await fetch(`${API_BASE}/ai/conversation/${conversationId}/message`, {
        method: "PUT",
        headers,
        body: JSON.stringify({
            message: "What is the weather in Paris?"
        })
    });

    if (!messageRes.ok) {
        const errorBody = await messageRes.text();
        console.error(`❌ Failed to send message: ${messageRes.status} ${messageRes.statusText}`);
        console.error(errorBody);
        process.exit(1);
    }

    const { parts: messageParts } = await messageRes.json();
    console.log("✅ Message response parts:", JSON.stringify(messageParts, null, 2));

    // Find if there's a function call
    const functionCallPart = messageParts.find((p: any) => p.functionCall);

    if (functionCallPart) {
        const call = functionCallPart.functionCall;
        console.log(`\n➡️  Model requested tool call for: ${call.name} with args`, call.args);

        // 3. Send back the tool result using the content endpoint
        console.log("➡️  Sending tool result back via /content endpoint...");

        // We format the function response according to Gemini's expected format
        const contentBlocks = [
            {
                functionResponse: {
                    name: call.name,
                    response: {
                        name: call.name,
                        content: { weather: "Sunny, 25 degrees Celsius" }
                    }
                }
            }
        ];

        const contentRes = await fetch(`${API_BASE}/ai/conversation/${conversationId}/content`, {
            method: "PUT",
            headers,
            body: JSON.stringify({
                content_blocks: contentBlocks
            })
        });

        if (!contentRes.ok) {
            const errorBody = await contentRes.text();
            console.error(`❌ Failed to send content: ${contentRes.status} ${contentRes.statusText}`);
            console.error(errorBody);
            process.exit(1);
        }

        const { parts: finalParts } = await contentRes.json();
        console.log("✅ Final response after tool call:", JSON.stringify(finalParts, null, 2));
    } else {
        console.log("ℹ️  No tool call was requested by the model.");
    }

    // 4. Delete the conversation
    console.log(`\n➡️  Deleting conversation ${conversationId}...`);
    const deleteRes = await fetch(`${API_BASE}/ai/conversation/${conversationId}`, {
        method: "DELETE",
        headers
    });

    if (!deleteRes.ok) {
        const errorBody = await deleteRes.text();
        console.error(`❌ Failed to delete conversation: ${deleteRes.status} ${deleteRes.statusText}`);
        console.error(errorBody);
        process.exit(1);
    }

    console.log("✅ Conversation deleted successfully.");
    console.log("\n🎉 All tests passed!");
}

runTest().catch(console.error);
