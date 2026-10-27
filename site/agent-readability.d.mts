export const origin: string;
export function handleReadability(request: Request): Promise<Response | null>;
export function advertiseMarkdown(response: Response, origin: string, mdPath?: string): Response;
