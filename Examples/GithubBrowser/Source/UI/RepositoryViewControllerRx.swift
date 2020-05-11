//
//  RepositoryViewController.swift
//  GithubBrowser
//
//  Created by Paul on 2016/7/16.
//  Copyright © 2016 Bust Out Solutions. All rights reserved.
//

import UIKit
import Siesta
import RxSwift

class RepositoryViewController: UIViewController {

    // MARK: UI Elements

    @IBOutlet weak var starIcon: UILabel!
    @IBOutlet weak var starButton: UIButton!
    @IBOutlet weak var starCountLabel: UILabel!
    @IBOutlet weak var descriptionLabel: UILabel!
    @IBOutlet weak var homepageButton: UIButton!
    @IBOutlet weak var languagesLabel: UILabel!
    @IBOutlet weak var contributorsLabel: UILabel!

    /**
    The input to this class - the repository to display. We allow it to change, although as it happens it's only
    called with a single value.
    Whether it's better to pass in a resource or an observable here is much the same argument as whether to define
    APIs in terms of resources or observables. See UserViewController for a discussion about that.
    */
    var repositoryResource: Observable<Resource>?

    private var statusOverlay = ResourceStatusOverlay()
    private var disposeBag = DisposeBag()


    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = SiestaTheme.darkColor
        statusOverlay.embed(in: self)
        statusOverlay.displayPriority = [.anyData, .loading, .error]  // Prioritize partial data over loading indicator

        configure()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        CommentaryViewController.publishCommentary(
                """
                Go back and then go forward to this screen again. Note how everything reappears <i>instantly</i> for a
                previously viewed repository, even though the data spans multiple API requests. This behavior <b>emerges
                naturally</b> from Siesta’s approach.

                The app says “load if needed” for all the data on this screen every time you visit it, but this is not
                expensive. Why not? Siesta (1) has a <b>configurable notion of staleness</b> to prevent excessive network
                requests, and (2) it <b>transparently handles ETags</b> with no additional code or configuration.

                Siesta fights the dreaded Massive View Controller by <b>allowing separation of concerns</b> without
                requiring excessive layers of abstraction. For example, on this screen…

                …when you star/unstar the repository, the spin-while-requesting animation is <b>completely decoupled</b>
                from the logic that asks for an updated star count. Though tightly grouped in the UI, they live in entirely
                different sections of code. Study that code, and you’ll understand the power of Siesta.
                """)
    }

    private func configure() {
        guard let repositoryResource = repositoryResource else {
            // Yikes - didn't expect that
            fatalError("where's my repositoryResource?")
        }


        // -- Resources --

        let repository: Observable<Repository?> = repositoryResource
                .watchedBy(statusOverlay: statusOverlay)
                .flatMapLatest { $0.rx.optionalContent() }

        let contributors: Observable<[User]?> = repository.map {
                    $0.flatMap(GitHubAPI.contributors)
                }
                .watchedBy(statusOverlay: statusOverlay)
                .flatMapLatest { $0?.rx.optionalContent() ?? .just(nil) }

        let languages: Observable<[String: Int]?> = repository.map {
                    $0.flatMap(GitHubAPI.languages)
                }
                .watchedBy(statusOverlay: statusOverlay)
                .flatMapLatest { $0?.rx.optionalContent() ?? .just(nil) }

        let isStarred: Observable<Bool> = repository.map {
                    $0.flatMap(GitHubAPI.currentUserStarred)
                }
                .watchedBy(statusOverlay: statusOverlay)
                .flatMapLatest { $0?.rx.optionalContent().map { $0 ?? false } ?? .just(false) }


        // -- Display --

        repository.bind { [unowned self] repository in
                    self.navigationItem.title = repository?.name
                    self.descriptionLabel?.text = repository?.description
                    self.homepageButton?.setTitle(repository?.homepage, for: .normal)
                }
                .disposed(by: disposeBag)

        contributors
                .map {
                    $0?.map { $0.login }.joined(separator: "\n")
                        ?? "-"
                }
                .bind(to: contributorsLabel.rx.text)
                .disposed(by: disposeBag)

        languages
                .map { $0?.keys.joined(separator: " • ") ?? "-" }
                .bind(to: languagesLabel.rx.text)
                .disposed(by: disposeBag)

        Observable.combineLatest(isStarred, repository)
                .bind { [unowned self] in
                    let (isStarred, repository) = $0

                    self.starCountLabel?.text = repository?.starCount?.description
                    self.starIcon?.text = isStarred ? "★" : "☆"
                    self.starButton?.setTitle(isStarred ? "Unstar" : "Star", for: .normal)
                    self.starButton?.isEnabled = (repository != nil)
                }
                .disposed(by: disposeBag)


        // -- Actions --

        homepageButton?.rx.tap
                .withLatestFrom(repository)
                .bind {
                    if let homepage = $0?.homepage,
                       let homepageURL = URL(string: homepage) {
                        UIApplication.shared.open(homepageURL)
                    }
                }
                .disposed(by: disposeBag)

        starButton?.rx.tap
            .withLatestFrom(Observable.combineLatest(isStarred, repository))
            .flatMap { [unowned self] args -> Observable<Void> in
                let isStarred = args.0
                guard let repository = args.1 else { return .empty() }

                // Two things of note here:
                //
                // 1. Siesta guarantees onCompletion will be called exactly once, no matter what the error condition, so
                //    it’s safe to rely on it to stop the animation and reenable the button. No error recovery gymnastics!
                //
                // 2. Who changes the button title between “Star” and “Unstar?” Who updates the star count?
                //
                //    Answer: the setStarred(…) method itself updates both the starred resource and the repository resource,
                //    if the call succeeds. And why don’t we have to take any special action to deal with that here in
                //    toggleStar(…)? Because RepositoryViewController is already observing those resources, and will thus
                //    pick up the changes made by setStarred(…) without any futher intervention.
                //
                //    This is exactly what chainable callbacks are for: we add our onCompletion callback, somebody else adds
                //    their onSuccess callback, and neither knows about the other. Decoupling is lovely! And because Siesta
                //    parses responses only once, no matter how many callback there are, the performance cost is negligible.

                self.startStarRequestAnimation()

                // Creating a Request and using its rx methods is at times a bad idea -  you might be better off
                // with Resource.rx.request* instead. Read the method comments to find out why.
                //
                // However, it works here, and we're sticking with the version of the api that gives us a Request, rather
                // than modifying it to be reactive.
                //
                // In fact in this case we could just as easily do away with the flatMap and use an onCompletion block on
                // GitHubAPI.setStarred, but this is an rx demo!
                return GitHubAPI.setStarred(!isStarred, repository: repository).rx.observable()
            }
            .bind { [unowned self] in
                self.stopStarRequestAnimation()
            }
            .disposed(by: disposeBag)
    }

    private func startStarRequestAnimation() {
        starButton?.isEnabled = false
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 1.6
        rotation.repeatCount = Float.infinity
        starIcon?.layer.add(rotation, forKey: "loadingIndicator")
    }

    @objc private func stopStarRequestAnimation() {
        starButton?.isEnabled = true
        let stopRotation = CASpringAnimation(keyPath: "transform.rotation.z")
        stopRotation.toValue = -Double.pi * 2 / 5
        stopRotation.damping = 6
        stopRotation.duration = stopRotation.settlingDuration
        starIcon?.layer.add(stopRotation, forKey: "loadingIndicator")
    }


    // Dummy actions just here for compatibility with the storyboard, which we share with the other implementations
    // of this controller.

    @IBAction func toggleStar(_ sender: Any) {
    }

    @IBAction func openHomepage(_ sender: Any) {
    }
}
