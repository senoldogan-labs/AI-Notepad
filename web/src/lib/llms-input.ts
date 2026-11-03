// `/llms.txt` ve `/llms-full.txt` uç noktalarının ortak girdisi: sitenin metinleri, dil listeleri, veri tablosu ve
// yayımlanmış blog yazıları (taslak ve tarihi gelmemiş yazılar `blogEntries` ile zaten ayrılır).
import { copy } from "../copy";
import { dataHandling } from "../data-handling";
import { operator } from "../legal/operator";
import { blogPostPath } from "../routes";
import { siteConfig } from "../site";
import { blogEntries, blogPost, type BlogPost } from "./blog";
import { noteLanguages, spokenLanguages } from "./languages";
import type { LlmsInput } from "./llms";

/** Derlemedeki girdiler. */
export async function llmsInput(): Promise<LlmsInput> {
  const origin: string = siteConfig.siteOrigin;
  const posts: readonly BlogPost[] = (await blogEntries()).map(blogPost);
  return {
    origin,
    copy,
    operator,
    dataHandling,
    spokenLanguages,
    noteLanguages,
    blogPosts: posts.map((post: BlogPost) => ({ title: post.title, description: post.description, url: `${origin}${blogPostPath(post.slug)}` })),
  };
}
