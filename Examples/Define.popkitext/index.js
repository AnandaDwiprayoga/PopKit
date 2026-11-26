const axios = require("axios");

// Needs the "network" entitlement in Config.json. Without it, axios rejects with
// error.code === "ERR_ENTITLEMENT" and nothing leaves your Mac.
async function define(input) {
  const word = input.text.trim().toLowerCase();
  if (!/^[a-z'-]+$/.test(word)) {
    popclip.showText("Select a single English word");
    return;
  }

  let entries;
  try {
    const response = await axios.get(
      "https://api.dictionaryapi.dev/api/v2/entries/en/" + encodeURIComponent(word),
      { timeout: 8000 }
    );
    entries = response.data;
  } catch (error) {
    if (error.response && error.response.status === 404) {
      popclip.showText(`No definition found for "${word}"`);
      return;
    }
    // Any other error shows ✗ and is written to the extension's log.
    throw error;
  }

  const lines = [];
  for (const entry of entries) {
    for (const meaning of entry.meanings) {
      lines.push(`${meaning.partOfSpeech}: ${meaning.definitions[0].definition}`);
    }
  }
  popclip.showText(`${word}\n\n${lines.join("\n\n")}`, { style: "large" });
}

module.exports = {
  actions: [
    {
      title: "Define",
      icon: "symbol:character.book.closed",
      requirements: ["text"],
      code: (input) => define(input),
    },
  ],
};
