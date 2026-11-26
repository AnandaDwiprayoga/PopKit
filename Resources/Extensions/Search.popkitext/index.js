const ENGINES = {
  google: "https://www.google.com/search?q=",
  duckduckgo: "https://duckduckgo.com/?q=",
  bing: "https://www.bing.com/search?q=",
};

module.exports = {
  actions: [
    {
      title: "Search",
      icon: "symbol:magnifyingglass",
      requirements: ["text"],
      code: (input, options) => {
        const base = ENGINES[options.engine] || ENGINES.google;
        popclip.openUrl(base + encodeURIComponent(input.text.trim()));
      },
    },
  ],
};
