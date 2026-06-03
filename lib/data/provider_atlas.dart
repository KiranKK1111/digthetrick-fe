/// The AI Model Provider Atlas — a static directory of model labs, inference
/// platforms, gateways, aggregators and generative-media providers, with
/// official links and free-vs-paid status.
///
/// Source: "The AI Model Provider Atlas · 2026" reference guide (compiled
/// June 2026). Pricing shifts month to month — treat as a snapshot and verify
/// on each provider's site. Rendered in the Providers screen's "Browse" tab,
/// each with a "Get API Key" link to the provider's portal.
library;

import 'package:flutter/material.dart';

/// Free-vs-paid status buckets (mirrors the guide's legend).
enum AtlasStatus { free, trial, open, paid, freemium, payg, subscription, notPublic }

extension AtlasStatusUi on AtlasStatus {
  String get label => switch (this) {
        AtlasStatus.free => 'Free tier',
        AtlasStatus.trial => 'Trial / credits',
        AtlasStatus.open => 'Open weights',
        AtlasStatus.paid => 'Paid',
        AtlasStatus.freemium => 'Freemium',
        AtlasStatus.payg => 'Pay-as-you-go',
        AtlasStatus.subscription => 'Subscription',
        AtlasStatus.notPublic => 'Not public',
      };

  Color get color => switch (this) {
        AtlasStatus.free => const Color(0xFF34D399), // green
        AtlasStatus.trial => const Color(0xFFFBBF24), // amber
        AtlasStatus.open => const Color(0xFF60A5FA), // blue
        AtlasStatus.paid => const Color(0xFFF87171), // red
        AtlasStatus.freemium => const Color(0xFF9CA3AF), // grey
        AtlasStatus.payg => const Color(0xFF22D3EE), // cyan
        AtlasStatus.subscription => const Color(0xFFC084FC), // purple
        AtlasStatus.notPublic => const Color(0xFF6B7280), // dim grey
      };

  /// True when there's a genuine no-card free path worth flagging.
  bool get isFreeish =>
      this == AtlasStatus.free ||
      this == AtlasStatus.open ||
      this == AtlasStatus.freemium ||
      this == AtlasStatus.trial;
}

class AtlasProvider {
  const AtlasProvider(this.name, this.url, this.status, [this.note = '']);

  final String name;

  /// Official link WITHOUT scheme (e.g. "platform.openai.com"). The
  /// "Get API Key" button opens https://<url>.
  final String url;
  final AtlasStatus status;

  /// Free/paid detail — covers limits, refresh cadence and caveats.
  final String note;
}

class AtlasCategory {
  const AtlasCategory(this.title, this.providers);
  final String title;
  final List<AtlasProvider> providers;
}

const List<AtlasCategory> kProviderAtlas = [
  AtlasCategory('Frontier & open-weight model labs', [
    AtlasProvider('OpenAI', 'platform.openai.com', AtlasStatus.paid,
        'Card required; free ChatGPT web tier'),
    AtlasProvider('Anthropic', 'anthropic.com', AtlasStatus.paid,
        'Free Claude web tier (~30–100 msgs/day)'),
    AtlasProvider('Google (Gemini)', 'aistudio.google.com', AtlasStatus.free,
        '1,500 req/day, no card — not a trial'),
    AtlasProvider('Meta (Llama)', 'llama.com', AtlasStatus.open,
        'Free to self-host'),
    AtlasProvider('xAI (Grok)', 'x.ai', AtlasStatus.freemium,
        'Paid API; free Grok via X'),
    AtlasProvider('DeepSeek', 'deepseek.com', AtlasStatus.open,
        'Open weights + low-cost paid API'),
    AtlasProvider('Mistral AI', 'mistral.ai', AtlasStatus.free,
        'Mistral Small / open weights + paid'),
    AtlasProvider('Cohere', 'cohere.com', AtlasStatus.trial, 'Trial → paid'),
    AtlasProvider('Z.AI / Zhipu (GLM)', 'vercel.com/ai-gateway', AtlasStatus.open,
        'Open weights; key via Vercel AI Gateway'),
    AtlasProvider('Alibaba (Qwen)', 'chat.qwen.ai', AtlasStatus.open,
        'Open weights + paid API'),
    AtlasProvider('Moonshot (Kimi)', 'kimi.com', AtlasStatus.freemium,
        'Free chat + paid API'),
    AtlasProvider('Magic.dev', 'magic.dev', AtlasStatus.notPublic,
        'Research only'),
  ]),
  AtlasCategory('Inference / API platforms', [
    AtlasProvider('Groq', 'groq.com', AtlasStatus.free,
        '14,400 req/day, no card + paid'),
    AtlasProvider('Cerebras', 'cerebras.ai', AtlasStatus.free,
        'Fastest throughput + paid'),
    AtlasProvider('SambaNova', 'sambanova.ai', AtlasStatus.free, 'Free tier + paid'),
    AtlasProvider('Together AI', 'together.ai', AtlasStatus.trial, '\$5 credit → paid'),
    AtlasProvider('Fireworks AI', 'fireworks.ai', AtlasStatus.trial, '\$1 credit → paid'),
    AtlasProvider('Replicate', 'replicate.com', AtlasStatus.payg, 'Pay-as-you-go'),
    AtlasProvider('DeepInfra', 'deepinfra.com', AtlasStatus.payg,
        'Pay-as-you-go · low cost'),
    AtlasProvider('Novita', 'novita.ai', AtlasStatus.trial, 'Trial → paid'),
    AtlasProvider('Hyperbolic', 'hyperbolic.xyz', AtlasStatus.trial, 'Trial → paid'),
    AtlasProvider('Nebius', 'nebius.com', AtlasStatus.paid, 'EU hosting'),
    AtlasProvider('Scaleway', 'scaleway.com', AtlasStatus.paid, 'EU hosting'),
    AtlasProvider('fal', 'fal.ai', AtlasStatus.payg, 'Pay-as-you-go · media focus'),
    AtlasProvider('Featherless AI', 'featherless.ai', AtlasStatus.subscription,
        'Subscription'),
  ]),
  AtlasCategory('Cloud gateways', [
    AtlasProvider('Azure OpenAI', 'azure.microsoft.com', AtlasStatus.paid,
        'Azure account'),
    AtlasProvider('Amazon Bedrock', 'aws.amazon.com/bedrock', AtlasStatus.paid,
        'AWS account'),
    AtlasProvider('Google Vertex AI', 'cloud.google.com/vertex-ai',
        AtlasStatus.paid, 'Free credits for new accounts'),
    AtlasProvider('Cloudflare Workers AI', 'developers.cloudflare.com/workers-ai',
        AtlasStatus.free, '10,000 neurons/day + paid'),
  ]),
  AtlasCategory('Aggregators / routers', [
    AtlasProvider('OpenRouter', 'openrouter.ai', AtlasStatus.free,
        '29 free models + paid (5% markup)'),
    AtlasProvider('Hugging Face', 'huggingface.co', AtlasStatus.free,
        'Unifies 15+ partners + paid'),
    AtlasProvider('TokenMix.ai', 'tokenmix.ai', AtlasStatus.paid,
        'Below-market routing'),
    AtlasProvider('Vercel AI SDK', 'sdk.vercel.ai', AtlasStatus.free,
        'Free SDK; you pay underlying providers'),
  ]),
  AtlasCategory('Bring-your-own-model GPU hosting', [
    AtlasProvider('Modal', 'modal.com', AtlasStatus.trial, 'Free credits → usage'),
    AtlasProvider('Baseten', 'baseten.co', AtlasStatus.trial, 'Trial → paid'),
    AtlasProvider('RunPod', 'runpod.io', AtlasStatus.payg, 'GPU rental'),
    AtlasProvider('Cerebrium', 'cerebrium.ai', AtlasStatus.free, 'Free tier + usage'),
  ]),
  AtlasCategory('Image generation', [
    AtlasProvider('Black Forest Labs (FLUX)', 'bfl.ai', AtlasStatus.open,
        'Open weights + paid API'),
    AtlasProvider('Midjourney', 'midjourney.com', AtlasStatus.subscription,
        'Subscription'),
    AtlasProvider('Stability AI', 'stability.ai', AtlasStatus.open,
        'Open weights + paid API'),
    AtlasProvider('Recraft', 'recraft.ai', AtlasStatus.freemium, 'Freemium'),
    AtlasProvider('Ideogram', 'ideogram.ai', AtlasStatus.freemium, 'Freemium'),
  ]),
  AtlasCategory('Video generation', [
    AtlasProvider('Google (Veo)', 'deepmind.google/models/veo', AtlasStatus.paid,
        'Via Gemini / Flow'),
    AtlasProvider('Runway', 'runwayml.com', AtlasStatus.freemium,
        'Limited free credits'),
    AtlasProvider('Kling (Kuaishou)', 'klingai.com', AtlasStatus.freemium, ''),
    AtlasProvider('ByteDance (Seedance)', 'doubao.com', AtlasStatus.paid,
        'Via Doubao'),
    AtlasProvider('MiniMax (Hailuo)', 'hailuoai.com', AtlasStatus.freemium, ''),
    AtlasProvider('Luma (Ray)', 'lumalabs.ai', AtlasStatus.freemium, ''),
    AtlasProvider('Tencent (Hunyuan)', 'hunyuan.tencent.com', AtlasStatus.open,
        'Open weights + paid'),
    AtlasProvider('Vidu (Shengshu)', 'vidu.com', AtlasStatus.freemium, ''),
    AtlasProvider('Pika', 'pika.art', AtlasStatus.freemium, ''),
    AtlasProvider('Lightricks (LTX)', 'ltx.studio', AtlasStatus.open,
        'Open weights + freemium'),
  ]),
  AtlasCategory('Audio, voice, music & embeddings', [
    AtlasProvider('ElevenLabs', 'elevenlabs.io', AtlasStatus.freemium,
        'Free character allowance'),
    AtlasProvider('Suno', 'suno.com', AtlasStatus.freemium, 'Music'),
    AtlasProvider('Udio', 'udio.com', AtlasStatus.freemium, 'Music'),
    AtlasProvider('Voyage AI', 'voyageai.com', AtlasStatus.free,
        'Embeddings + paid'),
  ]),
  AtlasCategory('Regional, sovereign & domain-specific', [
    AtlasProvider('Aleph Alpha (DE)', 'aleph-alpha.com', AtlasStatus.paid,
        'Enterprise'),
    AtlasProvider('AI21 Labs (IL)', 'ai21.com', AtlasStatus.trial, 'Trial → paid'),
    AtlasProvider('Sarvam AI (IN)', 'sarvam.ai', AtlasStatus.paid, 'Paid API'),
    AtlasProvider('Krutrim (IN)', 'olakrutrim.com', AtlasStatus.freemium, ''),
    AtlasProvider('Falcon / TII (UAE)', 'falconllm.tii.ae', AtlasStatus.open,
        'Open weights'),
    AtlasProvider('Baidu (Ernie, CN)', 'yiyan.baidu.com', AtlasStatus.freemium, ''),
    AtlasProvider('GitHub Copilot', 'github.com/features/copilot', AtlasStatus.paid,
        'Free for some students / OSS'),
    AtlasProvider('Cursor', 'cursor.com', AtlasStatus.freemium, ''),
    AtlasProvider('Windsurf (ex-Codeium)', 'windsurf.com', AtlasStatus.freemium, ''),
  ]),
];
