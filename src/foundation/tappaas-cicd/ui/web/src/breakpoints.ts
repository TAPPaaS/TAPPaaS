// breakpoints.ts — the breakpoints for code. These must agree with --bp-* on
// :root in styles.css, which CSS uses; test-console-design.sh checks the two.

export const BP = { sm: 640, md: 900, lg: 1100, xl: 1250 };
export const PHONE_QUERY = `(max-width: ${BP.sm}px)`;
