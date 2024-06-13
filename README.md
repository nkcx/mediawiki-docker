# mediawiki-docker
A Docker container for Mediawiki, based on the official `fpm-alpine` image, with a few QOL improvements to make it easier to manage extensions, themes, and configurations.

## Motivation
One of Mediawiki's greatest strengths is its vast extension network. However, extension development is haphazard at best, and ensuring compatible versions between the core Mediawiki software and third-party extensions is a difficult management challenge. Given that the Wikimedia Foundation's development goals are primarily focused on its own network, maintaining extension compatibility is at best an afterthought, so frequent updates to the core software in the face of non-Wikimedia Foundation extensions can easily break a working instance.

As a further challenge, the mechanisms behind containerization make managing extensions or themes especially awkward. Extensions can be considered part of the code-base, in the sense that, when the Mediawiki container is updated, the extensions should be updated as well. However, since extensions are controlled through configuration files, they sort of cross into userland. And of course, since we're dealing with disparate developers, updates are never going to happen on the same cadence.

The official Mediawiki Docker image suggests extending the image and adding extensions through the Docker file, which makes it impossible to customize through docker-compose. Alternatively, if you use volumes to add extensions or themes, then there's no mechanism to keep the extensions or themes in sync with the core Mediawiki software.

Lastly, Mediawiki extensions are installed via a mix of Git or Composer. Through Git, standard practice states that extensions should have a branch of the form `RELX_YY`, which corresponds to version X.YY of the core Mediawiki software. Through these branches, compatibility can be assumed (though not necessarily guaranteed). Unfortunately, through Composer, there is no mechanism to specify compatibility with the core Mediawiki version.

Currently, Mediawiki "requires" that compatibility is specified through an extension's `extension.json` file, but that is not always reliable. For example, the compatibility table for the Semantic Mediawiki extension reports that version 4.1.3 is compatible with 1.35.x through 1.39.x, but its `extension.json` shows compatibility `>= 1.35`.

As such, we need a way to better manage versioning, extensions/themes, and compatibility for the Mediawiki suite.

## Approach
All data about extensions/themes should be configurable via a `docker-compose` file. Preferably, users can simply provide a list of extensions, and the `entrypoint` script will take care of installing these extensions by determining the correct way to install them (git vs composer) by querying the relevant 
