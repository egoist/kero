import { createFileRoute } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { SiteLayout } from '@/components/site-layout'

export const Route = createFileRoute('/privacy')({
  head: () => ({
    meta: [
      { title: 'Privacy Policy — Kero for iOS' },
      {
        name: 'description',
        content:
          'How Kero for iOS stores SSH connection information and protects your privacy.',
      },
    ],
  }),
  component: Privacy,
})

function Privacy() {
  return (
    <SiteLayout>
      <article className="flex flex-col gap-9">
        <header className="flex flex-col gap-4 border-b border-border pb-8">
          <p className="text-[12px] tracking-[0.08em] text-brand uppercase">
            Kero for iOS
          </p>
          <div className="flex flex-col gap-3">
            <h2 className="font-sans text-[clamp(2.5rem,8vw,4.5rem)] leading-[0.95] font-semibold tracking-[-0.055em] text-foreground">
              Privacy Policy
            </h2>
            <p className="text-muted-foreground">Effective July 29, 2026</p>
          </div>
          <p className="max-w-[600px] text-foreground/90">
            Kero for iOS is a standalone SSH client. It requires no account and
            does not send analytics, telemetry, advertising data, tracking data,
            saved hosts, credentials, terminal activity, or usage data to Kero’s
            developer.
          </p>
        </header>

        <div className="grid gap-2 sm:grid-cols-3">
          <Assurance>No account</Assurance>
          <Assurance>No telemetry</Assurance>
          <Assurance>No tracking</Assurance>
        </div>

        <PolicySection title="Information stored on your device">
          <p>
            Kero stores saved host details, trusted server fingerprints, and app
            settings in protected app storage. Passwords and private SSH keys are
            stored in the iOS device-only Keychain. A credential can optionally
            require Face ID or the device passcode before use.
          </p>
          <p>
            These records are used only to provide the connections and preferences
            you request. Kero does not synchronize them to a Kero service.
          </p>
        </PolicySection>

        <PolicySection title="Network connections">
          <p>
            When you connect, Kero communicates directly with the SSH server you
            chose. Kero does not proxy terminal traffic through a Kero service. The
            selected server and its operator can receive your username,
            authentication attempt, commands, and terminal traffic according to
            that server’s own policies.
          </p>
          <p>
            Connecting to an address on your local network may cause iOS to request
            local-network permission. Kero uses that permission only to reach SSH
            servers you choose.
          </p>
        </PolicySection>

        <PolicySection title="Clipboard">
          <p>
            A remote terminal may ask Kero to copy text to the system clipboard.
            Kero does not permit a remote process to read the local clipboard.
          </p>
        </PolicySection>

        <PolicySection title="Retention and deletion">
          <p>
            Information remains on the device until you delete it or remove the
            app. You can delete individual hosts and keys, forget trusted server
            identities, or use <strong>Settings → Erase All Data</strong> to remove
            all Kero hosts, credentials, keys, trusted identities, and preferences
            from the device.
          </p>
        </PolicySection>

        <PolicySection title="Changes">
          <p>
            If the app’s data practices change, this policy and the App Store
            privacy answers will be updated before the changed build is released.
          </p>
        </PolicySection>

        <PolicySection title="Contact">
          <p>
            For privacy questions or support, email{' '}
            <a
              href="mailto:hi@egoist.dev"
              className="text-foreground underline decoration-border underline-offset-4 transition-colors hover:text-brand"
            >
              hi@egoist.dev
            </a>
            .
          </p>
        </PolicySection>
      </article>
    </SiteLayout>
  )
}

function Assurance({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-lg border border-brand/30 bg-brand/[0.055] px-4 py-3 text-center text-[13px] text-brand">
      {children}
    </div>
  )
}

function PolicySection({
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
