import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = AuthViewModel()
    @State private var isPasswordVisible = false

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack {
                switch viewModel.step {
                case .phoneInput:
                    phoneInputView
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            )
                        )

                case .codeInput:
                    codeInputView
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            )
                        )

                case .passwordInput:
                    passwordInputView
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            )
                        )
                }
            }
            .animation(.easeInOut(duration: 0.3), value: viewModel.step)
        }
        .task {
            viewModel.start(appState: appState)
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    // MARK: - Phone Input

    private var phoneInputView: some View {
        VStack(spacing: 0) {
            Spacer()

            stepIcon("antenna.radiowaves.left.and.right")
                .padding(.bottom, 24)

            Text("Your Phone Number")
                .font(.title3.bold())
                .padding(.bottom, 8)

            Text("Please confirm your country code\nand enter your phone number.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 40)

            underlinedTextField("Phone number", text: $viewModel.phoneNumber)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .padding(.horizontal, 40)

            errorLabel
                .padding(.horizontal, 40)

            Spacer()

            actionButton("Continue") {
                viewModel.submitPhone()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Code Input

    private var codeInputView: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                }
                .padding(.leading, 16)
                .padding(.top, 16)

                Spacer()
            }

            Spacer()

            stepIcon("iphone.gen3")
                .padding(.bottom, 24)

            Text("Enter Code")
                .font(.title3.bold())
                .padding(.bottom, 8)

            Text("We've sent the code to the Telegram\napp on your other device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 40)

            underlinedTextField("Code", text: $viewModel.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .padding(.horizontal, 40)

            errorLabel
                .padding(.horizontal, 40)

            Spacer()

            actionButton("Continue") {
                viewModel.submitCode()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Password Input

    private var passwordInputView: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    viewModel.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.medium))
                }
                .padding(.leading, 16)
                .padding(.top, 16)

                Spacer()
            }

            Spacer()

            stepIcon("lock.fill")
                .padding(.bottom, 24)

            Text("Enter Password")
                .font(.title3.bold())
                .padding(.bottom, 8)

            Group {
                if let hint = viewModel.passwordHint, !hint.isEmpty {
                    Text("Your account is protected with\nan additional password.\n\nHint: \(hint)")
                } else {
                    Text("Your account is protected with\nan additional password.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.bottom, 40)

            passwordField
                .padding(.horizontal, 40)

            errorLabel
                .padding(.horizontal, 40)

            Spacer()

            actionButton("Submit") {
                viewModel.submitPassword()
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Reusable Components

    private func stepIcon(_ systemName: String) -> some View {
        ZStack {
            Circle()
                .fill(.blue.opacity(0.12))
                .frame(width: 80, height: 80)

            Image(systemName: systemName)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.blue)
        }
    }

    private func underlinedTextField(
        _ placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(spacing: 0) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(.vertical, 12)

            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
        }
    }

    private var passwordField: some View {
        VStack(spacing: 0) {
            HStack {
                Group {
                    if isPasswordVisible {
                        TextField("Password", text: $viewModel.password)
                    } else {
                        SecureField("Password", text: $viewModel.password)
                    }
                }
                .textFieldStyle(.plain)
                .font(.body)

                Button {
                    isPasswordVisible.toggle()
                } label: {
                    Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 12)

            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
    }

    private func actionButton(
        _ title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(title)
                        .fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 22)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .disabled(viewModel.isLoading)
    }
}
