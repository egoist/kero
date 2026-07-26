import defaultMdxComponents from 'fumadocs-ui/mdx'
import { Accordion, Accordions } from 'fumadocs-ui/components/accordion'
import { Step, Steps } from 'fumadocs-ui/components/steps'
import type { MDXComponents } from 'mdx/types'

/**
 * Components every doc page can use without importing. `defaultMdxComponents`
 * already covers headings, links, code blocks, `Callout`, and `Card`/`Cards`.
 */
export function getMDXComponents(components?: MDXComponents) {
  return {
    ...defaultMdxComponents,
    Accordion,
    Accordions,
    Step,
    Steps,
    ...components,
  } satisfies MDXComponents
}
