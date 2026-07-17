import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import vm from "node:vm";

const contentScript = await readFile(new URL("../content.js", import.meta.url), "utf8");

test("registers its message listener only once when injected twice", () => {
  let listenerCount = 0;
  const context = vm.createContext({
    chrome: {
      runtime: {
        onMessage: {
          addListener() {
            listenerCount += 1;
          },
        },
      },
    },
  });

  vm.runInContext(contentScript, context);
  vm.runInContext(contentScript, context);

  assert.equal(listenerCount, 1);
});
