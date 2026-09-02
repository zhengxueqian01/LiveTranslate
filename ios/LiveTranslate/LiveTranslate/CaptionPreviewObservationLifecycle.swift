@MainActor
final class CaptionPreviewObservationLifecycle {
    private weak var viewModel: AppViewModel?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func pageDidAppear() {
        viewModel?.startCaptionObservation()
    }

    func pageDidDisappear() {
        viewModel?.stopCaptionObservation()
    }

    func pictureInPictureDidStop() {
        // The page lifecycle remains the sole owner of caption observation.
    }
}
