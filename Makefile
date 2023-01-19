wip-localhost:
	hugo server -D --bind 0 --baseUrl localhost

wip:
	hugo server -D --bind 0 --baseUrl ssh.tolmer.fr

publish-drafts:
	hugo -D -d public_drafts --baseURL https://drafts.confusedbit.dev

publish:
	hugo
