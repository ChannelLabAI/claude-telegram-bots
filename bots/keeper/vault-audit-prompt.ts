/**
 * Step 9b prompt assembly and budget guard.
 *
 * The estimate is intentionally dependency-free and approximate:
 * UTF-8 bytes / 3. English is usually overestimated while CJK may still vary
 * by tokenizer. Keeping the assembled estimate strictly below 150k leaves
 * headroom below the model's 200k context window.
 */

export const AUDIT_PROMPT_TOKEN_BUDGET = 150_000;

export interface AuditPromptPlan {
  userContent: string;
  estimatedTokens: number;
  hubNodesIncluded: number;
  inputBlocksIncluded: number;
  warnings: string[];
}

export function estimatePromptTokens(text: string): number {
  return Math.ceil(Buffer.byteLength(text, "utf8") / 3);
}

function composeUserContent(hubNodes: string[], inputBlocks: string[]): string {
  const hubList = hubNodes.length > 0 ? hubNodes.join(" | ") : "（無可用節點）";
  return `本批共用可用節點清單（所有筆記只能從此清單選擇）：\n${hubList}\n\n筆記批次：\n${inputBlocks.join("\n\n")}`;
}

function estimateCombinedPrompt(systemPrompt: string, userContent: string): number {
  return estimatePromptTokens(`${systemPrompt}\n\n${userContent}`);
}

export function buildAuditPrompt(
  systemPrompt: string,
  hubNodes: string[],
  inputBlocks: string[],
  tokenBudget = AUDIT_PROMPT_TOKEN_BUDGET,
): AuditPromptPlan {
  if (!Number.isFinite(tokenBudget) || tokenBudget < 1) {
    throw new Error(`invalid Step 9b prompt token budget: ${tokenBudget}`);
  }

  const warnings: string[] = [];
  let retainedBlocks = [...inputBlocks];
  const minimumHubs = hubNodes.slice(0, 1);

  // Fixed content can only be reduced by deferring trailing files. Preserve at
  // least one real hub when the index is non-empty so the strict linking rule
  // never asks the model to invent a node. Deferred files remain unaudited and
  // will be picked up by the next keeper batch.
  while (
    retainedBlocks.length > 1
    && estimateCombinedPrompt(systemPrompt, composeUserContent(minimumHubs, retainedBlocks)) >= tokenBudget
  ) {
    retainedBlocks.pop();
  }

  if (retainedBlocks.length < inputBlocks.length) {
    warnings.push(
      `WARN Step 9b prompt budget: deferred ${inputBlocks.length - retainedBlocks.length}/${inputBlocks.length} files to a later batch; no files marked audited or dropped`,
    );
  }

  const minimumUserContent = composeUserContent(minimumHubs, retainedBlocks);
  if (estimateCombinedPrompt(systemPrompt, minimumUserContent) >= tokenBudget) {
    throw new Error(
      `Step 9b prompt fixed content plus minimum hub index exceeds token budget ${tokenBudget}; refusing LLM call so files remain unaudited`,
    );
  }

  // Find the largest prefix of the stable, sorted hub index that fits. A
  // prefix keeps prompt generation deterministic across retries.
  let low = 0;
  let high = hubNodes.length;
  while (low < high) {
    const mid = Math.ceil((low + high) / 2);
    const candidate = composeUserContent(hubNodes.slice(0, mid), retainedBlocks);
    if (estimateCombinedPrompt(systemPrompt, candidate) < tokenBudget) low = mid;
    else high = mid - 1;
  }

  const retainedHubs = hubNodes.slice(0, low);
  if (retainedHubs.length < hubNodes.length) {
    warnings.push(
      `WARN Step 9b prompt budget: hub list truncated to ${retainedHubs.length}/${hubNodes.length} nodes; ${retainedBlocks.length} files retained`,
    );
  }

  const userContent = composeUserContent(retainedHubs, retainedBlocks);
  return {
    userContent,
    estimatedTokens: estimateCombinedPrompt(systemPrompt, userContent),
    hubNodesIncluded: retainedHubs.length,
    inputBlocksIncluded: retainedBlocks.length,
    warnings,
  };
}
