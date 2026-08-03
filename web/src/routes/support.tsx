import { createFileRoute, Link } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { SiteLayout } from '@/components/site-layout'

export const Route = createFileRoute('/support')({
  head: () => ({
    meta: [
      { title: 'Support — Kero' },
      {
        name: 'description',
        content: 'Get help with Kero for iOS or Kero for macOS.',
      },
    ],
  }),
  component: Support,
})

function Support() {
  return (
    <SiteLayout>
      <section className="flex flex-col gap-8">
        <header className="flex flex-col gap-4 border-b border-border pb-8">
          <p className="text-[12px] tracking-[0.08em] text-brand uppercase">
            Kero support
          </p>
          <div className="flex flex-col gap-3">
            <h2 className="font-sans text-[clamp(2.5rem,8vw,4.5rem)] leading-[0.95] font-semibold tracking-[-0.055em] text-foreground">
              How can we help?
            </h2>
            <p className="max-w-[560px] text-muted-foreground">
              For help with Kero for iPhone, iPad, or Mac, email the developer.
              You’ll receive a human reply.
            </p>
          </div>
          <a
            href="mailto:hi@egoist.dev?subject=Kero%20Support"
            className="inline-flex w-fit items-center gap-2 rounded-[9px] border border-brand/50 bg-brand/10 px-4 py-2 text-brand transition-colors hover:border-brand hover:bg-brand/15"
          >
            <span aria-hidden className="i-mingcute-mail-line size-4" />
            hi@egoist.dev
          </a>
        </header>

        <SupportSection title="Before you write">
          <p>Include the details that help identify the problem:</p>
          <ul className="grid list-none gap-2 p-0">
            <SupportItem>iPhone, iPad, or Mac model</SupportItem>
            <SupportItem>iOS, iPadOS, or macOS version</SupportItem>
            <SupportItem>Kero version from Settings or About</SupportItem>
            <SupportItem>What you expected and what happened instead</SupportItem>
            <SupportItem>Exact error text, with sensitive details removed</SupportItem>
          </ul>
        </SupportSection>

        <SupportSection title="SSH connection help">
          <p>
            Kero for iOS supports interactive SSH terminals with password or
            device-generated Ed25519 key authentication. It deliberately does not
            include file transfer.
          </p>
          <p>
            You may safely include a host-key fingerprint or public key when asking
            for help. Never email a password, private key, recovery code, production
            hostname, or unredacted terminal output.
          </p>
        </SupportSection>

        <SupportSection title="Privacy and security">
          <p>
            Kero has no account system or telemetry. Read the{' '}
            <Link
              to="/privacy"
              className="text-foreground underline decoration-border underline-offset-4 transition-colors hover:text-brand"
            >
              Kero for iOS privacy policy
            </Link>{' '}
            for details about on-device storage, network connections, and deletion.
          </p>
          <p>
            For a suspected security vulnerability, follow the private reporting
            instructions in the project’s{' '}
            <a
              href="https://github.com/egoist/kero/security"
              target="_blank"
              rel="noreferrer"
              className="text-foreground underline decoration-border underline-offset-4 transition-colors hover:text-brand"
            >
              Security page
            </a>
            .
          </p>
        </SupportSection>
      </section>
    </SiteLayout>
  )
}

function SupportSection({
  title,
  children,
}: {
  title: string
  children: ReactNode
}) {
  return (
    <section className="grid gap-3 sm:grid-cols-[190px_1fr] sm:gap-6">
      <h3 className="text-[13px] font-normal text-foreground">{title}</h3>
      <div className="flex flex-col gap-3 text-muted-foreground">{children}</div>
    </section>
  )
}

function SupportItem({ children }: { children: ReactNode }) {
  return (
    <li className="grid grid-cols-[12px_1fr] gap-2.5">
      <span aria-hidden className="text-brand">
        +
      </span>
      <span>{children}</span>
    </li>
  )
}
