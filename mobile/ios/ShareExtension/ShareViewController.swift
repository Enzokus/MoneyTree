import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let label = UILabel()
    private let done = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "Принимаем текст…"
        label.numberOfLines = 0
        label.textAlignment = .center
        done.setTitle("Готово", for: .normal)
        done.isEnabled = false
        done.addTarget(self, action: #selector(close), for: .touchUpInside)
        let content = UIStackView(arrangedSubviews: [label, done])
        content.axis = .vertical
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            content.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
        receive()
    }

    private func receive() {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, _ in
                let text = (item as? String) ?? (item as? NSAttributedString)?.string
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                DispatchQueue.main.async { self?.store(text) }
            }
        } else {
            store(items.compactMap { $0.attributedContentText?.string }.first)
        }
    }

    private func store(_ text: String?) {
        if let text {
            do {
                try ShareInbox.add(text)
                label.text = "Откройте «Денежное дерево», чтобы проверить и сохранить подписку."
            } catch {
                label.text = "Не удалось передать текст в «Денежное дерево»."
            }
        } else {
            label.text = "В выбранном материале не найден текст."
        }
        done.isEnabled = true
    }

    @objc private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
