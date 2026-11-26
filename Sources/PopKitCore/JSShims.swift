import Foundation

/// The JavaScript that runs in every extension's context before its own code: a CommonJS
/// `require`, `print`, `setTimeout`, an `axios` look-alike and the `popclip` object.
/// It is a function that takes the native bridge (see ExtensionRuntime) and returns
/// `{ boot, invoke }`.
///
/// Deliberately absent: `process`. Extensions written for PopClip test for it to tell Node from
/// PopClip, and refine's config.js rethrows when it exists.
enum JSShims {
    static let prelude = #"""
    (function (native) {
      var G = (function () { return this; })();
      var cache = {};
      var actions = [];

      function describe(e) {
        return (e && e.message !== undefined) ? String(e.message) : String(e);
      }

      // ---- print / console ----
      function fmt(v) {
        if (typeof v === "string") return v;
        if (v instanceof Error) return v.message;
        try { var s = JSON.stringify(v); return s === undefined ? String(v) : s; } catch (e) { return String(v); }
      }
      function print() { native.log(Array.prototype.map.call(arguments, fmt).join(" ")); }
      G.print = print;
      G.console = { log: print, info: print, warn: print, error: print, debug: print };

      // ---- timers ----
      G.setTimeout = function (fn, ms) {
        var extra = Array.prototype.slice.call(arguments, 2);
        return native.setTimeout(function () { fn.apply(null, extra); }, Number(ms) || 0);
      };
      G.clearTimeout = function (id) { native.clearTimeout(id); };

      // ---- axios ----
      function hasHeader(headers, name) {
        name = name.toLowerCase();
        return Object.keys(headers).some(function (k) { return k.toLowerCase() === name; });
      }
      function buildURL(url, params) {
        if (!params) return url;
        var query = Object.keys(params)
          .filter(function (k) { return params[k] !== undefined && params[k] !== null; })
          .map(function (k) { return encodeURIComponent(k) + "=" + encodeURIComponent(params[k]); })
          .join("&");
        if (!query) return url;
        return url + (url.indexOf("?") < 0 ? "?" : "&") + query;
      }
      function parseBody(body) {
        if (typeof body !== "string" || body === "") return body;
        try { return JSON.parse(body); } catch (e) { return body; }
      }
      function request(config) {
        config = Object.assign({}, config);
        var headers = Object.assign({}, config.headers || {});
        var data = config.data;
        if (data !== undefined && data !== null) {
          if (typeof data !== "string") {
            data = JSON.stringify(data);
            if (!hasHeader(headers, "content-type")) headers["Content-Type"] = "application/json";
          } else if (!hasHeader(headers, "content-type")) {
            headers["Content-Type"] = "application/x-www-form-urlencoded";
          }
        }
        var payload = JSON.stringify({
          method: String(config.method || "get").toUpperCase(),
          url: buildURL(String(config.url), config.params),
          headers: headers,
          data: data === undefined ? null : data,
          timeout: Number(config.timeout) || 0
        });
        return new Promise(function (resolve, reject) {
          native.http(payload, function (kind, status, headersJSON, body, message, code) {
            var response;
            if (status) {
              response = { status: status, statusText: "", headers: JSON.parse(headersJSON || "{}"),
                           data: parseBody(body), config: config, request: {} };
            }
            if (kind === "ok") { resolve(response); return; }
            var error = new Error(kind === "status" ? "Request failed with status code " + status : message);
            error.isAxiosError = true;
            error.config = config;
            if (code) error.code = code;
            else if (kind === "status") error.code = "ERR_BAD_REQUEST";
            if (response) error.response = response;
            reject(error);
          });
        });
      }
      var axios = function (config) { return request(config); };
      axios.request = request;
      ["get", "delete", "head", "options"].forEach(function (method) {
        axios[method] = function (url, config) {
          return request(Object.assign({}, config, { method: method, url: url }));
        };
      });
      ["post", "put", "patch"].forEach(function (method) {
        axios[method] = function (url, data, config) {
          return request(Object.assign({}, config, { method: method, url: url, data: data }));
        };
      });
      axios.default = axios;

      // ---- popclip ----
      var popclip = {
        modifiers: { shift: false, option: false, command: false, control: false },
        context: { appIdentifier: "", appName: "" },
        input: { text: "" },
        pasteText: function (text, options) {
          return new Promise(function (resolve) {
            native.paste(String(text), !!(options && options.restore), function () { resolve(); });
          });
        },
        copyText: function (text) { native.copy(String(text)); },
        showText: function (text, options) {
          options = options || {};
          native.show(String(text), !!options.preview, options.style ? String(options.style) : "");
        },
        openUrl: function (url) { native.openURL(String(url)); }
      };
      G.popclip = popclip;
      G.popkit = popclip;

      // ---- require ----
      function notFound(name) {
        var error = new Error("Cannot find module '" + name + "'");
        error.code = "MODULE_NOT_FOUND";
        return error;
      }
      function makeRequire(dir) {
        return function require(name) {
          name = String(name);
          if (name === "axios") return axios;
          if (name.charAt(0) !== ".") throw notFound(name);
          var parts = dir ? dir.split("/") : [];
          var segments = name.split("/");
          for (var i = 0; i < segments.length; i++) {
            var s = segments[i];
            if (s === "" || s === ".") continue;
            if (s === "..") {
              if (!parts.length) throw notFound(name);  // never above the extension folder
              parts.pop();
            } else {
              parts.push(s);
            }
          }
          var base = parts.join("/");
          var candidates = [base, base + ".js", base + ".json", base + "/index.js"];
          for (var j = 0; j < candidates.length; j++) {
            var file = candidates[j];
            if (cache[file]) return cache[file].exports;
            var source = native.read(file);
            if (source !== null && source !== undefined) return load(file, source);
          }
          throw notFound(name);
        };
      }
      function load(file, source) {
        if (cache[file]) return cache[file].exports;
        var module = { exports: {} };
        cache[file] = module;
        try {
          if (/\.json$/.test(file)) {
            module.exports = JSON.parse(source);
          } else {
            var slash = file.lastIndexOf("/");
            var dir = slash < 0 ? "" : file.slice(0, slash);
            new Function("module", "exports", "require", source)(module, module.exports, makeRequire(dir));
          }
        } catch (e) {
          delete cache[file];  // a failed load can be retried
          throw e;
        }
        return module.exports;
      }

      return {
        boot: function (file) {
          var source = native.read(file);
          if (source === null || source === undefined) throw new Error("Module file not found: " + file);
          var exported = load(file, source);
          actions = (exported && exported.actions) || [];
          if (!Array.isArray(actions)) throw new Error("module.exports.actions must be an array");
          return JSON.stringify(actions.map(function (a, i) {
            if (!a || typeof a.code !== "function") throw new Error("Action " + (i + 1) + " has no code function");
            return {
              title: String(a.title || ""),
              icon: a.icon == null ? null : String(a.icon),
              requirements: Array.isArray(a.requirements) ? a.requirements.map(String) : ["text"]
            };
          }));
        },
        invoke: function (index, payloadJSON, ok, fail) {
          try {
            var p = JSON.parse(payloadJSON);
            popclip.modifiers = p.modifiers;
            popclip.context = p.context;
            popclip.input = p.input;
            var result = actions[index].code(p.input, p.options);
            Promise.resolve(result).then(function () { ok(); }, function (e) { fail(describe(e)); });
          } catch (e) {
            fail(describe(e));
          }
        }
      };
    })
    """#
}
