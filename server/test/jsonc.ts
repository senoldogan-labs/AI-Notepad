/** JSONC without comments and trailing commas (strings, which hold `//` in URLs, are kept verbatim). Pure function. */
export function stripJsonc(source: string): string {
  let output: string = "";
  let index: number = 0;
  while (index < source.length) {
    const char: string = source[index] ?? "";
    if (char === '"') {
      const end: number = /"(?:[^"\\]|\\.)*"/y.exec(source.slice(index))?.[0].length ?? 1;
      output += source.slice(index, index + end);
      index += end;
    } else if (source.startsWith("//", index)) {
      const newline: number = source.indexOf("\n", index);
      index = newline < 0 ? source.length : newline;
    } else if (source.startsWith("/*", index)) {
      index = source.indexOf("*/", index) + 2;
    } else {
      output += char;
      index += 1;
    }
  }
  return output.replace(/,(\s*[}\]])/g, "$1");
}
