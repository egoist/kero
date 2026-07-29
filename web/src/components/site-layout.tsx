import { Link } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { SiteFooter } from '@/components/site-footer'

export function SiteLayout({
  children,
  headerContent,
}: {
  children: ReactNode
  headerContent?: ReactNode
}) {
  return (
    <main className="mx-auto flex max-w-[680px] flex-col gap-11 px-6 pt-[12vh] pb-[14vh] font-mono text-[14px] leading-[1.6]">
      <header className="flex flex-col gap-3">
        <h1 className="text-2xl font-bold tracking-[0.02em]">
          <Link to="/" className="flex items-center gap-2.5">
            <img
              src="/kero-icon.png"
              alt=""
              width={100}
              height={100}
              className="block size-12 rounded-md border border-zinc-600"
            />
            kero
          </Link>
        </h1>
        {headerContent}
      </header>

      {children}

      <SiteFooter />
    </main>
  )
}
