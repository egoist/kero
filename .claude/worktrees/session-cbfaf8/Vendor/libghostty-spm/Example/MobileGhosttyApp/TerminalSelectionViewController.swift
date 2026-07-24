import UIKit

final class TerminalSelectionViewController: UIViewController {
    private let pendingText: String
    private let pendingAnchorRange: NSRange?

    var onDone: (() -> Void)?

    private lazy var textView: UITextView = {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.accessibilityIdentifier = "terminal.selectionTextView"
        view.alwaysBounceVertical = true
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.backgroundColor = .clear
        view.textColor = .label
        view.textContainerInset = .init(top: 12, left: 12, bottom: 12, right: 12)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    init(text: String, anchorRange: NSRange?) {
        pendingText = text
        pendingAnchorRange = anchorRange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        textView.text = pendingText
        view.addSubview(textView)

        // Pin to view edges (not safe area) so scrolled content extends
        // under the transparent navigation bar / home indicator the way
        // iOS sheets expect. UIKit's contentInsetAdjustmentBehavior keeps
        // the initial scroll position below the nav bar via
        // adjustedContentInset.
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(handleDone)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "terminal.selectionDoneButton"
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.view.backgroundColor = .clear
        navigationController?.navigationBar.standardAppearance.configureWithTransparentBackground()
        navigationController?.navigationBar.scrollEdgeAppearance = navigationController?.navigationBar.standardAppearance
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()

        let nsText = textView.text as NSString
        if let range = pendingAnchorRange, NSMaxRange(range) <= nsText.length {
            textView.selectedRange = range
            textView.scrollRangeToVisible(range)
        } else {
            textView.selectAll(nil)
        }
    }

    @objc private func handleDone() {
        dismiss(animated: true) { [weak self] in
            self?.onDone?()
        }
    }
}
