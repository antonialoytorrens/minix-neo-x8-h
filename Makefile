#!/usr/bin/make -f

# --- SonarQube ---
ifneq (,$(wildcard ./.env))
include .env
export
endif

.PHONY: sonarqube
sonarqube:
	sonar-scanner \
		-Dsonar.token=$(SONAR_TOKEN) \
		-Dsonar.host.url=$(SONAR_HOST_URL) \
		-Dsonar.projectKey=$(SONAR_PROJECT_KEY)
