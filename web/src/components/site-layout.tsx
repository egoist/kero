import type { ReactNode } from 'react'
import { SiteFooter } from '@/components/site-footer'
import { HomeLink } from '@/components/site-links'
import { DEFAULT_LANGUAGE } from '@/lib/i18n'

export function SiteLayout({
  children,
  headerContent,
  lang = DEFAULT_LANGUAGE,
}: {
  children: ReactNode
  headerContent?: ReactNode
  lang?: string
}) {
  return (
    <main className="mx-auto flex max-w-[680px] flex-col gap-11 px-6 pt-[12vh] pb-[14vh] font-mono text-[14px] leading-[1.6]">
      <header className="flex flex-col gap-3">
        <h1 className="text-2xl font-bold tracking-[0.02em]">
          <HomeLink lang={lang} className="flex items-center gap-2.5">
            <img
              src="/kero-icon.png"
              alt=""
              width={100}
              height={100}
              className="block size-12 rounded-md border border-zinc-600"
            />
            kero
          </HomeLink>
        </h1>
        {headerContent}
      </header>

      {children}

      <SiteFooter lang={lang} />
    </main>
  )
}
