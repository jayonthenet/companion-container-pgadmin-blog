.PHONY: init,apply,deploy,clean

init:
	@terraform init -upgrade
	@terraform apply -auto-approve

apply:
	@terraform apply -auto-approve

deploy:
	@humctl score deploy -f score.yaml --app ${HUMANITEC_APP} --org ${HUMANITEC_ORG} --env ${HUMANITEC_ENV} --wait

clean:
	@terraform destroy -auto-approve
